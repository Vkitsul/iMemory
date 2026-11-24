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
                report += "scan stalled after 120 s: probably a permission request with no answer\n"
                write(report)
                NSApp.terminate(nil)
                return
            }
            if case .failed(let message) = model.phase {
                report += "scan failed: \(message)\n"
                write(report)
                NSApp.terminate(nil)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let session = model.session, let explorer = model.explorer else { return }
        let tree = session.tree
        report += "entries \(tree.count), scan \(Format.seconds(session.duration))\n"

        func step(_ name: String, action: () -> Void) async {
            meter.reset()
            action()
            try? await Task.sleep(for: .milliseconds(300))
            while explorer.isRefreshing {
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(150))
            let rows = explorer.visibleRows.count
            let line = "\(name.padding(toLength: 34, withPad: " ", startingAt: 0)) rows \(String(rows).padding(toLength: 8, withPad: " ", startingAt: 0)) worst stall \(Int(meter.worst * 1000)) ms\n"
            report += line
            write(report)
        }

        await step("overview") { model.section = .overview }
        await snapshot("overview")

        await step("open explore") { model.section = .explore }
        await snapshot("explore-root")

        for level in 1...6 {
            guard let next = explorer.visibleRows.first(where: { $0.kind == .directory })?.id else { break }
            await step("enter level \(level)") { explorer.show(next) }
        }
        await snapshot("explore-deep")

        await step("go up") { explorer.goUp() }

        if let first = explorer.visibleRows.first?.id {
            await step("select a row") { explorer.selection = first }
            await snapshot("explore-selection")
            await step("clear selection") { explorer.selection = nil }
        }

        await step("back to overview") { model.section = .overview }
        await step("reopen explore") { model.section = .explore }

        let crowded = (0..<tree.count)
            .map { NodeID(index: UInt32($0)) }
            .max { tree.childCount(of: $0) < tree.childCount(of: $1) }
        if let crowded {
            await step("most crowded folder") { explorer.show(crowded) }
            await snapshot("explore-crowded")
            await step("sort by name") { explorer.sort = RowSort(key: .name, ascending: true) }
            await step("sort by date") { explorer.sort = RowSort(key: .modified, ascending: false) }
            await step("search text") { explorer.searchText = "a" }
            await step("clear search") { explorer.searchText = "" }
            await step("sort by size") { explorer.sort = RowSort(key: .allocated, ascending: false) }
        }

        await step("back to root") { explorer.show(tree.root) }
        await step("filter over 1 GB") { explorer.sizeFilter = .oneGB }
        await step("clear filter") { explorer.sizeFilter = .any }

        if let window = NSApp.windows.first(where: { $0.isVisible }) {
            let frame = window.frame
            for width in stride(from: frame.width, to: frame.width - 300, by: -60) {
                await step("resize to \(Int(width))") {
                    window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: width, height: frame.height), display: true)
                }
            }
            window.setFrame(frame, display: true)
        }

        // Shows the confirmation and goes back. This route must never call `confirm()`.
        await step("open cleanup") { model.section = .cleanup }
        await snapshot("cleanup")
        if !model.cleanup.selectedCandidates.isEmpty {
            await step("open confirmation") { model.cleanup.phase = .confirming }
            await snapshot("cleanup-confirmation")
            await step("cancel confirmation") { model.cleanup.phase = .choosing }
        }
        await step("open developer") { model.section = .developer }
        await snapshot("developer")
        // Selects a risky rule only to see its confirmation, which is then cancelled.
        let selectionBefore = model.cleanup.selectedIDs
        model.cleanup.selectedIDs.formUnion(model.cleanup.candidates.map(\.id))
        await step("open developer confirmation") { model.cleanup.phase = .confirming }
        await snapshot("developer-confirmation")
        await step("cancel developer confirmation") { model.cleanup.phase = .choosing }
        model.cleanup.selectedIDs = selectionBefore
        await step("open apps") { model.section = .apps }
        await snapshot("apps")
        if let first = session.apps.first(where: { $0.leftovers.count > 1 }) {
            await step("open app detail") { model.trash.selectedAppID = first.id }
            try? await Task.sleep(for: .seconds(2))
            await snapshot("app-detail")
            await step("open app confirmation") { model.trash.prepareUninstall(first) }
            await snapshot("app-confirmation-real")
            await step("cancel app confirmation") { model.trash.cancel() }
        }
        await step("open large files") { model.section = .files }
        await snapshot("large-files")
        // A real search, which only reads. Its results are looked at and then cancelled.
        await step("open duplicates") { model.section = .duplicates }
        await snapshot("duplicates-start")
        let homeInTree = String(NSHomeDirectory().drop { $0 == "/" })
        let searchStart = ContinuousClock.now
        model.duplicates.search(tree: tree, homeInTree: homeInTree)
        while true {
            if case .finished = model.duplicates.phase { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if case .finished(let found) = model.duplicates.phase {
            report += "duplicates: \(found.groups.count) groups, \(Format.bytes(found.groups.map(\.reclaimable).reduce(0, +))) recoverable, \(found.filesConsidered) files, unreadable \(found.unreadableFiles), in \(Format.seconds(searchStart.duration(to: .now)))\n"
            let clones = found.groups.flatMap(\.files).filter(\.isClone).count
            report += "entries that are clones: \(clones); groups with fewer than 2 copies: \(found.groups.filter { $0.copies < 2 }.count)\n"
            if let first = found.groups.first, let file = first.files.first {
                model.duplicates.selected = [file.id]
                try? await Task.sleep(for: .milliseconds(400))
                await snapshot("duplicates")
                if let selection = try? DuplicateSelection(groups: found.groups, selected: [file.id]) {
                    await step("open duplicates confirmation") { model.trash.prepareDuplicates(selection) }
                    await snapshot("duplicates-confirmation")
                    await step("cancel duplicates confirmation") { model.trash.cancel() }
                }
                model.duplicates.selected = []
            } else {
                await snapshot("duplicates")
            }
        }
        await step("open automation") { model.section = .automation }
        await snapshot("automation")
        report += "scheduled cleanup on: \(model.automation.settings.cleansOnSchedule), due: \(model.automation.isCleanupDue)\n"
        await step("open history") { model.section = .history }
        await snapshot("history")

        report += await fakeCleanup()
        report += await fakeUninstall()
        report += "apps: \(session.apps.count); with known last use: \(session.apps.filter { $0.lastUsed != nil }.count); large files: \(session.largeFiles.count)\n"
        for app in session.apps.sorted(by: { $0.allocated > $1.allocated }).prefix(5) {
            let estimate = RecoveryEstimator.estimate(paths: [app.path])
            report += "  \(app.name): takes \(Format.bytes(app.allocated)), private \(Format.bytes(app.privateBytes)), returns \(Format.bytes(estimate.recoverable)), unread \(estimate.unreadableFolders)\n"
        }

        report += "cleanup: \(model.cleanup.candidates.map { "\($0.id) \(Format.bytes($0.allocated)) in \($0.itemCount) items" }.joined(separator: "; "))\n"
        report += "selected by default: \(model.cleanup.selectedIDs.sorted().joined(separator: ", "))\n"
        report += "resident memory \(Format.bytes(residentBytes()))\ndone\n"
        write(report)
        NSApp.terminate(nil)
    }

    /// Runs a whole cleanup through the real screens, on files created for the purpose in
    /// a fake home inside the output folder. Never reaches the real home: the model and
    /// the executor only know the fake one.
    private func fakeCleanup() async -> String {
        let fakeHome = output + "/fake-home"
        let cache = fakeHome + "/Library/Caches/SampleIMemory"
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
                title: "Sample cache",
                explanation: "Files created for the automated check.",
                level: .safe,
                roots: ["~/Library/Caches/SampleIMemory"]
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
            await snapshot("cleanup-report")

            guard case .finished(let result) = probe.phase else { return "fake cleanup: unexpected state\n" }
            probe.phase = .choosing
            model.section = .history
            try await Task.sleep(for: .milliseconds(400))
            await snapshot("history-full")

            let remaining = (try? FileManager.default.contentsOfDirectory(atPath: cache))?.count ?? -1
            return """
            fake cleanup: deleted \(result.removedItemCount), left \(remaining), problems \(result.issueCount), \
            expected \(Format.bytes(result.expectedAllocated)), measured \(Format.bytes(result.measuredFreed)), history entries \(probe.history.count)

            """
        } catch {
            return "fake cleanup failed: \(error)\n"
        }
    }

    /// Runs a whole uninstall through the real screens, on an app made up in a fake home.
    /// The Trash here is a folder inside the fake home, so the real one is never touched.
    private func fakeUninstall() async -> String {
        // Laid out like the real disk, with the home below the root.
        let fakeRoot = output + "/fake-home-apps"
        let fakeHome = fakeRoot + "/Users/sample"
        let fakeTrash = fakeRoot + "/FakeTrash"
        let bundle = fakeRoot + "/Applications/SampleIMemory.app"
        let realTrash = model.trash
        defer {
            model.trash = realTrash
        }

        do {
            let manager = FileManager.default
            try manager.createDirectory(atPath: bundle + "/Contents", withIntermediateDirectories: true)
            try manager.createDirectory(atPath: fakeHome + "/Library/Caches/local.sample.imemory", withIntermediateDirectories: true)
            try manager.createDirectory(atPath: fakeHome + "/Library/Application Support/SampleIMemory", withIntermediateDirectories: true)
            try manager.createDirectory(atPath: fakeTrash, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "local.sample.imemory",
                "CFBundleName": "SampleIMemory",
                "CFBundleExecutable": "SampleIMemory",
            ], format: .xml, options: 0)
            try plist.write(to: URL(fileURLWithPath: bundle + "/Contents/Info.plist"))
            try Data(count: 5_000_000).write(to: URL(fileURLWithPath: bundle + "/Contents/data"))
            try Data(count: 1_000_000).write(to: URL(fileURLWithPath: fakeHome + "/Library/Caches/local.sample.imemory/c"))
            try Data(count: 1_000_000).write(to: URL(fileURLWithPath: fakeHome + "/Library/Application Support/SampleIMemory/d"))

            let tree = try await FileScanner().scan(root: fakeRoot).tree
            let apps = AppFinder.apps(tree: tree, appFolders: ["Applications"], homeInTree: "Users/sample", realRoot: fakeRoot) { _ in nil }
            guard let app = apps.first else { return "fake uninstall: app not found\n" }

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
            await snapshot("app-confirmation")
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
            fake uninstall: app removed \(!manager.fileExists(atPath: bundle)), in fake trash \(moved), \
            cache removed \(!manager.fileExists(atPath: fakeHome + "/Library/Caches/local.sample.imemory")), \
            data kept \(manager.fileExists(atPath: fakeHome + "/Library/Application Support/SampleIMemory")), \
            problems \(finished?.issueCount ?? -1)

            """
        } catch {
            return "fake uninstall failed: \(error)\n"
        }
    }

    private func write(_ report: String) {
        try? report.write(toFile: output + "/results.txt", atomically: true, encoding: .utf8)
    }

    /// Asks whoever runs the check to capture the window, because capturing from inside
    /// the app would need Screen Recording permission. Capturing sometimes fails while a
    /// sheet animates, so it tries again. As a last resort it draws the views itself, which
    /// needs no permission but loses materials and vibrant text.
    private func snapshot(_ name: String) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) else { return }
        let image = output + "/\(name).png"
        let request = output + "/request-\(name)"

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
