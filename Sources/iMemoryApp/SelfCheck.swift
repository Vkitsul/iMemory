import AppKit
import AppsKit
import CleanKit
import DuplicateKit
import RulesKit
import ScanKit

/// Drives the app through a fixed route and records how long the main thread blocks,
/// then quits. Runs only when `IMEMORY_SELFCHECK` names an output folder, and it is
/// read-only like the rest of the app. See `Scripts/check-app.sh`.
struct SelfCheck {
    let model: AppModel
    let output: String

    func run() async {
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        var report = ""
        let meter = StallMeter()
        let monitor = Task { await meter.watch() }
        defer { monitor.cancel() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while model.isScanning || model.session == nil {
            // A permission prompt nobody answers must not keep the check running forever.
            if ContinuousClock.now > deadline {
                report += "scansione ferma dopo 120 s: probabile richiesta di permesso senza risposta\n"
                write(report)
                NSApp.terminate(nil)
                return
            }
            if case .failed(let message) = model.phase {
                report += "scansione fallita: \(message)\n"
                write(report)
                NSApp.terminate(nil)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let session = model.session, let explorer = model.explorer else { return }
        let tree = session.tree
        report += "voci \(tree.count), scansione \(Format.seconds(session.duration))\n"

        func step(_ name: String, action: () -> Void) async {
            meter.reset()
            action()
            try? await Task.sleep(for: .milliseconds(300))
            while explorer.isRefreshing {
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(150))
            let rows = explorer.visibleRows.count
            let line = "\(name.padding(toLength: 34, withPad: " ", startingAt: 0)) righe \(String(rows).padding(toLength: 8, withPad: " ", startingAt: 0)) blocco massimo \(Int(meter.worst * 1000)) ms\n"
            report += line
            write(report)
        }

        await step("panoramica") { model.section = .overview }
        await snapshot("panoramica")

        await step("apri esplora") { model.section = .explore }
        await snapshot("esplora-radice")

        for level in 1...6 {
            guard let next = explorer.visibleRows.first(where: { $0.kind == .directory })?.id else { break }
            await step("entra livello \(level)") { explorer.show(next) }
        }
        await snapshot("esplora-profonda")

        await step("torna su") { explorer.goUp() }

        if let first = explorer.visibleRows.first?.id {
            await step("seleziona una riga") { explorer.selection = first }
            await snapshot("esplora-selezione")
            await step("togli selezione") { explorer.selection = nil }
        }

        await step("torna a panoramica") { model.section = .overview }
        await step("riapri esplora") { model.section = .explore }

        let crowded = (0..<tree.count)
            .map { NodeID(index: UInt32($0)) }
            .max { tree.childCount(of: $0) < tree.childCount(of: $1) }
        if let crowded {
            await step("cartella più affollata") { explorer.show(crowded) }
            await snapshot("esplora-affollata")
            await step("ordina per nome") { explorer.sort = RowSort(key: .name, ascending: true) }
            await step("ordina per data") { explorer.sort = RowSort(key: .modified, ascending: false) }
            await step("cerca testo") { explorer.searchText = "a" }
            await step("togli ricerca") { explorer.searchText = "" }
            await step("ordina per spazio") { explorer.sort = RowSort(key: .allocated, ascending: false) }
        }

        await step("torna alla radice") { explorer.show(tree.root) }
        await step("filtro oltre 1 GB") { explorer.sizeFilter = .oneGB }
        await step("togli filtro") { explorer.sizeFilter = .any }

        if let window = NSApp.windows.first(where: { $0.isVisible }) {
            let frame = window.frame
            for width in stride(from: frame.width, to: frame.width - 300, by: -60) {
                await step("ridimensiona a \(Int(width))") {
                    window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: width, height: frame.height), display: true)
                }
            }
            window.setFrame(frame, display: true)
        }

        // Shows the confirmation and goes back. This route must never call `confirm()`.
        await step("apri pulizia") { model.section = .cleanup }
        await snapshot("pulizia")
        if !model.cleanup.selectedCandidates.isEmpty {
            await step("apri conferma") { model.cleanup.phase = .confirming }
            await snapshot("pulizia-conferma")
            await step("annulla conferma") { model.cleanup.phase = .choosing }
        }
        await step("apri sviluppatore") { model.section = .developer }
        await snapshot("sviluppatore")
        // Selects a risky rule only to see its confirmation, which is then cancelled.
        let selectionBefore = model.cleanup.selectedIDs
        model.cleanup.selectedIDs.formUnion(model.cleanup.candidates.map(\.id))
        await step("apri conferma sviluppatore") { model.cleanup.phase = .confirming }
        await snapshot("sviluppatore-conferma")
        await step("annulla conferma sviluppatore") { model.cleanup.phase = .choosing }
        model.cleanup.selectedIDs = selectionBefore
        await step("apri app") { model.section = .apps }
        await snapshot("app")
        if let first = session.apps.first(where: { $0.leftovers.count > 1 }) {
            await step("apri dettaglio app") { model.trash.selectedAppID = first.id }
            try? await Task.sleep(for: .seconds(2))
            await snapshot("app-dettaglio")
            await step("apri conferma app") { model.trash.prepareUninstall(first) }
            await snapshot("app-conferma-reale")
            await step("annulla conferma app") { model.trash.cancel() }
        }
        await step("apri file grandi") { model.section = .files }
        await snapshot("file-grandi")
        // A real search, which only reads. Its results are looked at and then cancelled.
        await step("apri duplicati") { model.section = .duplicates }
        await snapshot("duplicati-inizio")
        let homeInTree = String(NSHomeDirectory().drop { $0 == "/" })
        let searchStart = ContinuousClock.now
        model.duplicates.search(tree: tree, homeInTree: homeInTree)
        while true {
            if case .finished = model.duplicates.phase { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if case .finished(let found) = model.duplicates.phase {
            report += "duplicati: \(found.groups.count) gruppi, \(Format.bytes(found.groups.map(\.reclaimable).reduce(0, +))) recuperabili, \(found.filesConsidered) file, non leggibili \(found.unreadableFiles), in \(Format.seconds(searchStart.duration(to: .now)))\n"
            let clones = found.groups.flatMap(\.files).filter(\.isClone).count
            report += "voci che sono cloni: \(clones); gruppi con meno di 2 copie: \(found.groups.filter { $0.copies < 2 }.count)\n"
            if let first = found.groups.first, let file = first.files.first {
                model.duplicates.selected = [file.id]
                try? await Task.sleep(for: .milliseconds(400))
                await snapshot("duplicati")
                if let selection = try? DuplicateSelection(groups: found.groups, selected: [file.id]) {
                    await step("apri conferma duplicati") { model.trash.prepareDuplicates(selection) }
                    await snapshot("duplicati-conferma")
                    await step("annulla conferma duplicati") { model.trash.cancel() }
                }
                model.duplicates.selected = []
            } else {
                await snapshot("duplicati")
            }
        }
        await step("apri automazione") { model.section = .automation }
        await snapshot("automazione")
        report += "pulizia programmata attiva: \(model.automation.settings.cleansOnSchedule), dovuta: \(model.automation.isCleanupDue)\n"
        await step("apri cronologia") { model.section = .history }
        await snapshot("cronologia")

        report += await fakeCleanup()
        report += await fakeUninstall()
        report += "app: \(session.apps.count); con ultimo utilizzo noto: \(session.apps.filter { $0.lastUsed != nil }.count); file grandi: \(session.largeFiles.count)\n"
        for app in session.apps.sorted(by: { $0.allocated > $1.allocated }).prefix(5) {
            let estimate = RecoveryEstimator.estimate(paths: [app.path])
            report += "  \(app.name): occupa \(Format.bytes(app.allocated)), privato \(Format.bytes(app.privateBytes)), torna \(Format.bytes(estimate.recoverable)), non letti \(estimate.unreadableFolders)\n"
        }

        report += "pulizia: \(model.cleanup.candidates.map { "\($0.id) \(Format.bytes($0.allocated)) in \($0.itemCount) voci" }.joined(separator: "; "))\n"
        report += "selezionate di partenza: \(model.cleanup.selectedIDs.sorted().joined(separator: ", "))\n"
        report += "memoria residente \(Format.bytes(residentBytes()))\nfine\n"
        write(report)
        NSApp.terminate(nil)
    }

    /// Runs a whole cleanup through the real screens, on files created for the purpose in
    /// a fake home inside the output folder. Never reaches the real home: the model and
    /// the executor only know the fake one.
    private func fakeCleanup() async -> String {
        let fakeHome = output + "/casa-finta"
        let cache = fakeHome + "/Library/Caches/ProvaIMemory"
        let realCleanup = model.cleanup
        defer { model.cleanup = realCleanup }

        do {
            try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
            for index in 0..<3 {
                let bytes = Data((0..<20_000_000).lazy.map { _ in UInt8.random(in: 0...255) })
                try bytes.write(to: URL(fileURLWithPath: cache + "/file\(index)"))
            }
            let rule = CleaningRule(
                id: "prova",
                title: "Cache di prova",
                explanation: "File creati per il controllo automatico.",
                level: .safe,
                roots: ["~/Library/Caches/ProvaIMemory"]
            )
            let tree = try await FileScanner().scan(root: fakeHome).tree
            let candidates = CleanupPlanner.candidates(
                tree: tree,
                home: fakeHome,
                homeInTree: "",
                catalog: try RuleCatalog(rules: [rule])
            )

            let probe = CleanupModel(home: fakeHome, historyFile: URL(fileURLWithPath: fakeHome + "/cronologia.jsonl"))
            probe.update(candidates: candidates)
            model.cleanup = probe
            model.section = .cleanup
            try await Task.sleep(for: .milliseconds(400))

            probe.phase = .confirming
            try await Task.sleep(for: .milliseconds(400))
            probe.confirm()

            while true {
                if case .finished = probe.phase { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(400))
            await snapshot("pulizia-report")

            guard case .finished(let result) = probe.phase else { return "pulizia finta: stato inatteso\n" }
            probe.phase = .choosing
            model.section = .history
            try await Task.sleep(for: .milliseconds(400))
            await snapshot("cronologia-piena")

            let remaining = (try? FileManager.default.contentsOfDirectory(atPath: cache))?.count ?? -1
            return """
            pulizia finta: voci eliminate \(result.removedItemCount), rimaste \(remaining), problemi \(result.issueCount), \
            attesi \(Format.bytes(result.expectedAllocated)), misurati \(Format.bytes(result.measuredFreed)), voci in cronologia \(probe.history.count)

            """
        } catch {
            return "pulizia finta fallita: \(error)\n"
        }
    }

    /// Runs a whole uninstall through the real screens, on an app made up in a fake home.
    /// The Trash here is a folder inside the fake home, so the real one is never touched.
    private func fakeUninstall() async -> String {
        // Laid out like the real disk, with the home below the root.
        let fakeRoot = output + "/casa-finta-app"
        let fakeHome = fakeRoot + "/Users/prova"
        let fakeTrash = fakeRoot + "/CestinoFinto"
        let bundle = fakeRoot + "/Applications/ProvaIMemory.app"
        let realTrash = model.trash
        defer {
            model.trash = realTrash
        }

        do {
            let manager = FileManager.default
            try manager.createDirectory(atPath: bundle + "/Contents", withIntermediateDirectories: true)
            try manager.createDirectory(atPath: fakeHome + "/Library/Caches/local.prova.imemory", withIntermediateDirectories: true)
            try manager.createDirectory(atPath: fakeHome + "/Library/Application Support/ProvaIMemory", withIntermediateDirectories: true)
            try manager.createDirectory(atPath: fakeTrash, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "local.prova.imemory",
                "CFBundleName": "ProvaIMemory",
                "CFBundleExecutable": "ProvaIMemory",
            ], format: .xml, options: 0)
            try plist.write(to: URL(fileURLWithPath: bundle + "/Contents/Info.plist"))
            try Data(count: 5_000_000).write(to: URL(fileURLWithPath: bundle + "/Contents/dati"))
            try Data(count: 1_000_000).write(to: URL(fileURLWithPath: fakeHome + "/Library/Caches/local.prova.imemory/c"))
            try Data(count: 1_000_000).write(to: URL(fileURLWithPath: fakeHome + "/Library/Application Support/ProvaIMemory/d"))

            let tree = try await FileScanner().scan(root: fakeRoot).tree
            let apps = AppFinder.apps(tree: tree, appFolders: ["Applications"], homeInTree: "Users/prova", realRoot: fakeRoot) { _ in nil }
            guard let app = apps.first else { return "disinstallazione finta: app non trovata\n" }

            let probe = TrashModel(
                policy: TrashPolicy(home: fakeHome, appFolders: [fakeRoot + "/Applications"]),
                moveToTrash: { url in
                    try FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: fakeTrash + "/" + url.lastPathComponent))
                }
            )
            var finished: CleanupReport?
            probe.onFinished = { finished = $0 }
            model.trash = probe
            model.section = .apps
            try await Task.sleep(for: .milliseconds(500))

            probe.prepareUninstall(app)
            try await Task.sleep(for: .seconds(1))
            await snapshot("app-conferma")
            probe.confirm()

            while true {
                if case .finished = probe.phase { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(400))
            await snapshot("app-report")
            probe.closeReport()

            let moved = (try? manager.contentsOfDirectory(atPath: fakeTrash).sorted()) ?? []
            return """
            disinstallazione finta: app rimossa \(!manager.fileExists(atPath: bundle)), nel cestino finto \(moved), \
            cache rimossa \(!manager.fileExists(atPath: fakeHome + "/Library/Caches/local.prova.imemory")), \
            dati rimasti \(manager.fileExists(atPath: fakeHome + "/Library/Application Support/ProvaIMemory")), \
            problemi \(finished?.issueCount ?? -1)

            """
        } catch {
            return "disinstallazione finta fallita: \(error)\n"
        }
    }

    private func write(_ report: String) {
        try? report.write(toFile: output + "/risultati.txt", atomically: true, encoding: .utf8)
    }

    /// Asks whoever runs the check to capture the window, because capturing from inside
    /// the app would need Screen Recording permission. Capturing sometimes fails while a
    /// sheet animates, so it tries again. As a last resort it draws the views itself, which
    /// needs no permission but loses materials and vibrant text.
    private func snapshot(_ name: String) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) else { return }
        let image = output + "/\(name).png"
        let request = output + "/richiesta-\(name)"

        for _ in 0..<3 where !FileManager.default.fileExists(atPath: image) {
            try? String(window.windowNumber).write(toFile: request, atomically: true, encoding: .utf8)
            for _ in 0..<30 where !FileManager.default.fileExists(atPath: image) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? FileManager.default.removeItem(atPath: request)
        }
        guard !FileManager.default.fileExists(atPath: image) else { return }

        draw(window.attachedSheet?.contentView ?? window.contentView, to: image)
    }

    /// Drawn over a dark background, because in dark mode the views' text is light and
    /// their real background is a material that drawing can't reproduce.
    private func draw(_ view: NSView?, to path: String) {
        guard let view, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)

        let result = NSImage(size: view.bounds.size)
        result.lockFocus()
        NSColor(white: 0.13, alpha: 1).setFill()
        view.bounds.fill()
        bitmap.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        result.unlockFocus()

        guard let data = result.tiffRepresentation, let output = NSBitmapImageRep(data: data) else { return }
        try? output.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func residentBytes() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)
    }
}

/// Measures how late the main actor wakes from short sleeps, which is how long it
/// was blocked and therefore how long the app could not respond.
private final class StallMeter {
    private(set) var worst: Double = 0

    func reset() { worst = 0 }

    func watch() async {
        let interval = 0.004
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let start = clock.now
            try? await Task.sleep(for: .seconds(interval))
            let parts = start.duration(to: clock.now).components
            let elapsed = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            worst = max(worst, elapsed - interval)
        }
    }
}
