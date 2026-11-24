import Foundation
import Testing
@testable import CleanKit
@testable import RulesKit
import ScanKit
import Synchronization

/// A fake home in a temporary folder. Every test here deletes only inside it.
final class FakeHome {
    let path: String

    init() throws {
        var template = Array((FileManager.default.temporaryDirectory.path + "/imemory-clean-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw POSIXError(.EIO) }
        let resolved = realpath(template, nil)!
        path = String(cString: resolved)
        free(resolved)
    }

    deinit {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/rm")
        process.arguments = ["-rf", path]
        try? process.run()
        process.waitUntilExit()
    }

    func at(_ relative: String) -> String { path + "/" + relative }

    func folder(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: at(relative), withIntermediateDirectories: true)
    }

    func file(_ relative: String, size: Int = 10_000) throws {
        var bytes = [UInt8](repeating: 0, count: size)
        if size > 0 { arc4random_buf(&bytes, size) }
        guard FileManager.default.createFile(atPath: at(relative), contents: Data(bytes)) else {
            throw POSIXError(.EIO)
        }
    }

    func exists(_ relative: String) -> Bool {
        var info = stat()
        return lstat(at(relative), &info) == 0
    }

    func link(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: at(relative), withDestinationPath: destination)
    }

    /// Scans the fake home and plans `rule` against it, as the app does on the real one.
    func plan(_ rule: CleaningRule, now: Date = .now) async throws -> CleanupCandidate {
        let tree = try await FileScanner().scan(root: path).tree
        let catalog = try RuleCatalog(rules: [rule])
        return try #require(CleanupPlanner.candidates(tree: tree, home: path, homeInTree: "", catalog: catalog, now: now).first)
    }

    func executor(running: Set<String> = []) -> CleanupExecutor {
        CleanupExecutor(
            home: path,
            volumePath: "/System/Volumes/Data",
            runningProcesses: { running }
        )
    }
}

private let cacheRule = CleaningRule(
    id: "test.cache",
    title: "Cache di prova",
    explanation: "",
    level: .safe,
    roots: ["~/Library/Caches/Prova"]
)

private func firstIssue(_ report: CleanupReport) -> RemovalProblem? {
    report.rules.first?.issues.first?.problem
}

@Suite("Eliminazione: percorso normale")
struct RemovalTests {
    @Test("Elimina il contenuto e lascia la cartella")
    func removesContentsKeepsRoot() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova/sotto/ancora")
        try home.file("Library/Caches/Prova/a")
        try home.file("Library/Caches/Prova/sotto/b")
        try home.file("Library/Caches/Prova/sotto/ancora/c")
        try home.file("Library/Caches/Altra")

        let report = await home.executor().run([try await home.plan(cacheRule)])

        #expect(home.exists("Library/Caches/Prova"))
        #expect(!home.exists("Library/Caches/Prova/a"))
        #expect(!home.exists("Library/Caches/Prova/sotto"))
        #expect(home.exists("Library/Caches/Altra"))
        #expect(report.issueCount == 0)
        #expect(report.removedItemCount == 2)
        #expect(report.rules[0].removedBytes >= 30_000)
    }

    @Test("Le voci comparse dopo la scansione restano")
    func newEntriesSurvive() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova")
        try home.file("Library/Caches/Prova/vecchio")

        let plan = try await home.plan(cacheRule)
        try home.file("Library/Caches/Prova/nuovo")
        _ = await home.executor().run([plan])

        #expect(!home.exists("Library/Caches/Prova/vecchio"))
        #expect(home.exists("Library/Caches/Prova/nuovo"))
    }

    @Test("Le voci già sparite non sono un errore")
    func missingEntryIsFine() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova")
        try home.file("Library/Caches/Prova/f")

        let plan = try await home.plan(cacheRule)
        try FileManager.default.removeItem(atPath: home.at("Library/Caches/Prova/f"))
        let report = await home.executor().run([plan])

        #expect(report.issueCount == 0)
    }

    @Test("La regola per età elimina solo i file vecchi, anche annidati")
    func ageRule() async throws {
        let home = try FakeHome()
        try home.folder("Library/Logs/App")
        try home.file("Library/Logs/recente")
        try home.file("Library/Logs/App/vecchio")
        try home.file("Library/Logs/App/recente")
        var times = [timeval(tv_sec: 1_000_000_000, tv_usec: 0), timeval(tv_sec: 1_000_000_000, tv_usec: 0)]
        #expect(utimes(home.at("Library/Logs/App/vecchio"), &times) == 0)

        let rule = CleaningRule(id: "logs", title: "", explanation: "", level: .safe, roots: ["~/Library/Logs"], minimumAgeDays: 30)
        let plan = try await home.plan(rule)
        #expect(plan.itemCount == 1)

        _ = await home.executor().run([plan])

        #expect(!home.exists("Library/Logs/App/vecchio"))
        #expect(home.exists("Library/Logs/App/recente"))
        #expect(home.exists("Library/Logs/recente"))
    }

    @Test("L'annullamento ferma prima della voce successiva")
    func cancellation() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova")
        for index in 0..<5 {
            try home.file("Library/Caches/Prova/f\(index)")
        }
        let plan = try await home.plan(cacheRule)
        let executor = home.executor()
        executor.cancel()

        let report = await executor.run([plan])

        #expect(report.wasCancelled)
        #expect(report.removedItemCount == 0)
        #expect(home.exists("Library/Caches/Prova/f0"))
    }
}

@Suite("Eliminazione: casi avversi")
struct AdversarialTests {
    @Test("Una radice che è un link simbolico viene rifiutata")
    func rootIsSymlink() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches")
        try home.folder("Documents")
        try home.file("Documents/tesi")
        try home.link("Library/Caches/Prova", to: home.at("Documents"))

        // Il piano è costruito a mano: la scansione non segue i link, quindi non ne produrrebbe uno.
        let plan = CleanupCandidate(rule: cacheRule, roots: [
            PlanRoot(path: home.at("Library/Caches/Prova"), fileID: 1, items: [
                PlanItem(relativePath: "tesi", fileID: 1, allocated: 1, privateBytes: 1),
            ]),
        ])
        let report = await home.executor().run([plan])

        #expect(home.exists("Documents/tesi"))
        #expect(firstIssue(report) == .symbolicLinkInPath)
    }

    @Test("Una radice sostituita da un link dopo la scansione viene rifiutata")
    func rootReplacedAfterScan() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova")
        try home.file("Library/Caches/Prova/tesi")
        try home.folder("Documents")
        try home.file("Documents/tesi")

        let plan = try await home.plan(cacheRule)
        try FileManager.default.removeItem(atPath: home.at("Library/Caches/Prova"))
        try home.link("Library/Caches/Prova", to: home.at("Documents"))
        let report = await home.executor().run([plan])

        #expect(home.exists("Documents/tesi"))
        #expect(firstIssue(report) == .symbolicLinkInPath)
    }

    @Test("Un link simbolico in un punto intermedio del percorso viene rifiutato")
    func symlinkInAncestor() async throws {
        let home = try FakeHome()
        try home.folder("Altrove/Caches/Prova")
        try home.file("Altrove/Caches/Prova/f")
        try home.folder("Library")

        let plan = try await home.plan(CleaningRule(
            id: "x", title: "", explanation: "", level: .safe, roots: ["~/Library/Caches/Prova"]
        ), ifExists: false, stub: "f")
        try home.link("Library/Caches", to: home.at("Altrove/Caches"))
        let report = await home.executor().run([plan])

        #expect(home.exists("Altrove/Caches/Prova/f"))
        #expect(firstIssue(report) == .symbolicLinkInPath)
    }

    @Test("Un link simbolico nel piano elimina il link e non la destinazione")
    func symlinkItem() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova")
        try home.folder("Documents")
        try home.file("Documents/tesi")
        try home.link("Library/Caches/Prova/fuori", to: home.at("Documents"))

        let report = await home.executor().run([try await home.plan(cacheRule)])

        #expect(!home.exists("Library/Caches/Prova/fuori"))
        #expect(home.exists("Documents/tesi"))
        #expect(report.issueCount == 0)
    }

    @Test("Un link simbolico annidato non viene attraversato")
    func nestedSymlink() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova/sotto/ancora")
        try home.folder("Documents")
        try home.file("Documents/tesi")
        try home.link("Library/Caches/Prova/sotto/ancora/fuori", to: home.at("Documents"))
        try home.link("Library/Caches/Prova/sotto/file-fuori", to: home.at("Documents/tesi"))

        _ = await home.executor().run([try await home.plan(cacheRule)])

        #expect(!home.exists("Library/Caches/Prova/sotto"))
        #expect(home.exists("Documents/tesi"))
    }

    @Test("Una cartella sostituita da un link durante il piano non viene seguita")
    func directorySwappedForSymlink() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova/dati")
        try home.file("Library/Caches/Prova/dati/f")
        try home.folder("Documents")
        try home.file("Documents/tesi")

        let plan = try await home.plan(cacheRule)
        try FileManager.default.removeItem(atPath: home.at("Library/Caches/Prova/dati"))
        try home.link("Library/Caches/Prova/dati", to: home.at("Documents"))
        let report = await home.executor().run([plan])

        #expect(home.exists("Documents/tesi"))
        #expect(firstIssue(report) == .changedSinceScan)
    }

    @Test("Un file sostituito dopo la scansione non viene eliminato", arguments: [false, true])
    func fileReplaced(sameSize: Bool) async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova")
        try home.file("Library/Caches/Prova/f")

        let plan = try await home.plan(cacheRule)
        try home.file("Library/Caches/Prova/segnaposto")
        try FileManager.default.removeItem(atPath: home.at("Library/Caches/Prova/f"))
        try home.file("Library/Caches/Prova/f", size: sameSize ? 10_000 : 77_000)
        try FileManager.default.removeItem(atPath: home.at("Library/Caches/Prova/segnaposto"))
        let report = await home.executor().run([plan])

        #expect(home.exists("Library/Caches/Prova/f"))
        #expect(firstIssue(report) == .changedSinceScan)
    }

    @Test("Una radice ricreata dopo la scansione viene rifiutata")
    func rootRecreated() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova")
        try home.file("Library/Caches/Prova/f")

        let plan = try await home.plan(cacheRule)
        try FileManager.default.moveItem(atPath: home.at("Library/Caches/Prova"), toPath: home.at("Library/Caches/Spostata"))
        try home.folder("Library/Caches/Prova")
        try home.file("Library/Caches/Prova/f")
        let report = await home.executor().run([plan])

        #expect(home.exists("Library/Caches/Prova/f"))
        #expect(home.exists("Library/Caches/Spostata/f"))
        #expect(firstIssue(report) == .changedSinceScan)
    }

    @Test("Un percorso di voce che esce dalla radice viene rifiutato", arguments: [
        "../fuori", "sotto/../../fuori", "/etc/hosts", "./f", "", "a//b", "..",
    ])
    func itemEscapesRoot(path: String) async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova/sotto")
        try home.file("Library/Caches/fuori")

        let rootID = try #require(try FileManager.default.attributesOfItem(atPath: home.at("Library/Caches/Prova"))[.systemFileNumber] as? UInt64)
        let plan = CleanupCandidate(rule: cacheRule, roots: [
            PlanRoot(path: home.at("Library/Caches/Prova"), fileID: rootID, items: [
                PlanItem(relativePath: path, fileID: 1, allocated: 1, privateBytes: 1),
            ]),
        ])
        let report = await home.executor().run([plan])

        #expect(home.exists("Library/Caches/fuori"))
        #expect(firstIssue(report) == .outsideRoot)
    }

    @Test("Un piano con una radice che la regola non nomina viene rifiutato")
    func rootNotInRule() async throws {
        let home = try FakeHome()
        try home.folder("Documents")
        try home.file("Documents/tesi")
        let attributes = try FileManager.default.attributesOfItem(atPath: home.at("Documents"))
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: home.at("Documents/tesi"))

        let plan = CleanupCandidate(rule: cacheRule, roots: [
            PlanRoot(
                path: home.at("Documents"),
                fileID: try #require(attributes[.systemFileNumber] as? UInt64),
                items: [PlanItem(
                    relativePath: "tesi",
                    fileID: try #require(fileAttributes[.systemFileNumber] as? UInt64),
                    allocated: 1,
                    privateBytes: 1
                )]
            ),
        ])
        let report = await home.executor().run([plan])

        #expect(home.exists("Documents/tesi"))
        #expect(firstIssue(report) == .outsideRoot)
    }

    @Test("Un piano con una regola non valida viene rifiutato anche se costruito a mano")
    func invalidRuleInPlan() async throws {
        let home = try FakeHome()
        try home.folder("Documents")
        try home.file("Documents/tesi")
        let attributes = try FileManager.default.attributesOfItem(atPath: home.at("Documents"))
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: home.at("Documents/tesi"))
        let badRule = CleaningRule(id: "cattiva", title: "", explanation: "", level: .safe, roots: ["~/Documents"])

        let plan = CleanupCandidate(rule: badRule, roots: [
            PlanRoot(
                path: home.at("Documents"),
                fileID: try #require(attributes[.systemFileNumber] as? UInt64),
                items: [PlanItem(
                    relativePath: "tesi",
                    fileID: try #require(fileAttributes[.systemFileNumber] as? UInt64),
                    allocated: 1,
                    privateBytes: 1
                )]
            ),
        ])
        let report = await home.executor().run([plan])

        #expect(home.exists("Documents/tesi"))
        #expect(firstIssue(report) == .outsideRoot)
    }

    @Test("Con l'app proprietaria aperta la regola non tocca nulla")
    func ownerRunning() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova")
        try home.file("Library/Caches/Prova/f")
        let rule = CleaningRule(id: "app", title: "", explanation: "", level: .review, roots: ["~/Library/Caches/Prova"], ownerProcesses: ["App Di Prova"])

        let plan = try await home.plan(rule)
        let report = await home.executor(running: ["App Di Prova"]).run([plan])

        #expect(home.exists("Library/Caches/Prova/f"))
        #expect(report.rules[0].blockedBy == ["App Di Prova"])
        #expect(report.removedItemCount == 0)
    }

    @Test("Un hard link eliminato non tocca l'altro nome del file")
    func hardLinkSurvives() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova")
        try home.folder("Documents")
        try home.file("Documents/tesi")
        try FileManager.default.linkItem(atPath: home.at("Documents/tesi"), toPath: home.at("Library/Caches/Prova/link"))

        let report = await home.executor().run([try await home.plan(cacheRule)])

        #expect(!home.exists("Library/Caches/Prova/link"))
        #expect(home.exists("Documents/tesi"))
        #expect(report.rules[0].removedBytes == 0)
    }

    @Test("Una cartella illeggibile è segnalata e il resto viene eliminato")
    func unreadableSubfolder() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova/dati/chiusa")
        try home.file("Library/Caches/Prova/dati/chiusa/f")
        try home.file("Library/Caches/Prova/dati/aperto")
        try home.file("Library/Caches/Prova/altro")

        let plan = try await home.plan(cacheRule)
        #expect(chmod(home.at("Library/Caches/Prova/dati/chiusa"), 0) == 0)
        defer { chmod(home.at("Library/Caches/Prova/dati/chiusa"), 0o755) }
        let report = await home.executor().run([plan])

        #expect(!home.exists("Library/Caches/Prova/altro"))
        #expect(!home.exists("Library/Caches/Prova/dati/aperto"))
        #expect(home.exists("Library/Caches/Prova/dati/chiusa/f") || firstIssue(report) != nil)
        #expect(firstIssue(report) == .system(code: EACCES))
    }

    @Test("Un file protetto è segnalato e il resto viene eliminato")
    func immutableFile() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova")
        try home.file("Library/Caches/Prova/protetto")
        try home.file("Library/Caches/Prova/normale")
        #expect(chflags(home.at("Library/Caches/Prova/protetto"), UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(home.at("Library/Caches/Prova/protetto"), 0) }

        let report = await home.executor().run([try await home.plan(cacheRule)])

        #expect(home.exists("Library/Caches/Prova/protetto"))
        #expect(!home.exists("Library/Caches/Prova/normale"))
        #expect(report.issueCount == 1)
    }

    @Test("Un volume montato dentro la cartella non viene toccato")
    func mountedVolume() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova/dati/volume")
        try home.file("Library/Caches/Prova/dati/f")
        let image = home.at("disco.dmg")
        try runTool("/usr/bin/hdiutil", ["create", "-size", "5m", "-fs", "APFS", "-volname", "ProvaIMemory", "-quiet", image])
        try runTool("/usr/bin/hdiutil", ["attach", image, "-mountpoint", home.at("Library/Caches/Prova/dati/volume"), "-nobrowse", "-quiet"])
        defer { try? runTool("/usr/bin/hdiutil", ["detach", home.at("Library/Caches/Prova/dati/volume"), "-force", "-quiet"]) }
        try home.file("Library/Caches/Prova/dati/volume/dentro")

        let report = await home.executor().run([try await home.plan(cacheRule)])

        #expect(home.exists("Library/Caches/Prova/dati/volume/dentro"))
        #expect(!home.exists("Library/Caches/Prova/dati/f"))
        #expect(firstIssue(report) == .otherVolume)
    }

    @Test("I percorsi oltre PATH_MAX vengono eliminati")
    func deepPath() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova")
        let component = String(repeating: "p", count: 200)
        var descriptor = open(home.at("Library/Caches/Prova"), O_RDONLY | O_DIRECTORY)
        for _ in 0..<30 {
            #expect(mkdirat(descriptor, component, 0o755) == 0)
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY)
            close(descriptor)
            descriptor = next
        }
        close(openat(descriptor, "in-fondo", O_CREAT | O_WRONLY, 0o644))
        close(descriptor)

        let report = await home.executor().run([try await home.plan(cacheRule)])

        #expect(report.issueCount == 0)
        #expect(!home.exists("Library/Caches/Prova/" + component))
    }
}

@Suite("Spazio misurato", .serialized)
struct MeasuredSpaceTests {
    /// Every test that compares against what the volume reports belongs in this suite:
    /// run side by side, they write hundreds of MB and falsify each other's figures.
    @Test("La stima del recupero coincide con lo spazio davvero liberato", arguments: [true, false])
    func estimateMatchesRealDeletion(cloneInside: Bool) throws {
        // Other apps write to the disk too, so a single reading can be off. A wrong estimate
        // fails every attempt, while outside noise doesn't last for three in a row.
        var attempts: [String] = []
        for _ in 0..<3 {
            let home = try FakeHome()
            try home.folder("app")
            try home.file("app/a", size: 100_000_000)
            try home.file("app/normale", size: 50_000_000)
            #expect(clonefile(home.at("app/a"), home.at(cloneInside ? "app/b" : "fuori"), 0) == 0)

            let estimate = RecoveryEstimator.estimate(paths: [home.at("app")])
            #expect(estimate.recoverable >= (cloneInside ? 149_000_000 : 49_000_000))
            #expect(estimate.recoverable <= (cloneInside ? 151_000_000 : 51_000_000))

            let before = try VolumeCapacity(path: "/System/Volumes/Data").volumeUsed
            try FileManager.default.removeItem(atPath: home.at("app"))
            let freed = before - (try VolumeCapacity(path: "/System/Volumes/Data").volumeUsed)

            if abs(Double(freed - estimate.recoverable)) <= 10_000_000 { return }
            attempts.append("liberati \(freed), stimati \(estimate.recoverable)")
        }
        Issue.record("mai entro 10 MB: \(attempts)")
    }

    @Test("Il volume si legge una volta prima e una dopo, senza attese")
    func readsVolumeOnlyTwice() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova")
        try home.file("Library/Caches/Prova/f")
        let plan = try await home.plan(cacheRule)

        let reads = Mutex<[Int64]>([1_000, 400])
        let count = Mutex(0)
        let executor = CleanupExecutor(
            home: home.path,
            volumePath: "/System/Volumes/Data",
            runningProcesses: { [] },
            volumeUsed: { _ in
                count.withLock { $0 += 1 }
                return reads.withLock { $0.removeFirst() }
            }
        )
        let report = await executor.run([plan])

        #expect(report.measuredFreed == 600)
        #expect(count.withLock { $0 } == 2)
    }

    @Test("I due dati divergono solo oltre il margine")
    func divergence() {
        func report(measured: Int64, removed: Int64) -> CleanupReport {
            var rule = RuleResult(ruleID: "r", title: "", expectedAllocated: 0, expectedPrivate: 0)
            rule.removedBytes = removed
            return CleanupReport(id: UUID(), date: .now, rules: [rule], measuredFreed: measured, wasCancelled: false)
        }

        #expect(!report(measured: 400_000_000, removed: 400_000_000).figuresDiverge)
        #expect(!report(measured: 385_000_000, removed: 400_000_000).figuresDiverge)
        #expect(report(measured: 300_000_000, removed: 400_000_000).figuresDiverge)
        #expect(!report(measured: 1_000_000, removed: 5_000_000).figuresDiverge)
    }

    /// Writes and frees real space on the data volume, inside the fake home. Other
    /// activity on the disk moves the figure a little, hence the large file.
    @Test("Lo spazio misurato è entro il 5% di quello atteso")
    func measuredMatchesExpected() async throws {
        // As above: outside noise doesn't last for three attempts, a real error does.
        var attempts: [String] = []
        for _ in 0..<3 {
            let home = try FakeHome()
            try home.folder("Library/Caches/Prova")
            for index in 0..<4 {
                try home.file("Library/Caches/Prova/f\(index)", size: 100_000_000)
            }
            let plan = try await home.plan(cacheRule)
            let report = await home.executor().run([plan])

            let expected = Double(report.expectedAllocated)
            #expect(expected >= 400_000_000)
            // Il dato sui file non dipende dalle altre app, quindi deve tornare sempre.
            #expect(abs(Double(report.rules[0].removedBytes) - expected) <= expected * 0.01)

            if abs(Double(report.measuredFreed) - expected) <= expected * 0.05 { return }
            attempts.append("misurato \(report.measuredFreed), atteso \(report.expectedAllocated)")
        }
        Issue.record("mai entro il 5%: \(attempts)")
    }

    @Test("Eliminare un clone libera poco, e la stima privata lo prevede")
    func cloneFreesLittle() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova")
        try home.folder("Altrove")
        try home.file("Altrove/originale", size: 200_000_000)
        #expect(clonefile(home.at("Altrove/originale"), home.at("Library/Caches/Prova/clone"), 0) == 0)

        let plan = try await home.plan(cacheRule)
        #expect(plan.allocated >= 200_000_000)
        #expect(plan.privateBytes < 1_000_000)

        let report = await home.executor().run([plan])

        #expect(home.exists("Altrove/originale"))
        #expect(report.measuredFreed < 20_000_000, "misurato \(report.measuredFreed)")
    }
}

@Suite("Regole")
struct RuleTests {
    @Test("Il catalogo incluso è valido")
    func builtInCatalog() throws {
        let catalog = try RuleCatalog.builtIn()
        #expect(!catalog.rules.isEmpty)
        for rule in catalog.rules {
            #expect(!rule.title.isEmpty && !rule.explanation.isEmpty)
        }
    }

    @Test("Le radici vietate vengono rifiutate", arguments: [
        "~", "~/", "/", "/System", "/Applications", "/Users", "~/Documents", "~/Desktop", "~/Downloads",
        "~/Pictures", "~/Library", "~/Library/Caches", "~/Library/Application Support",
        "~/Library/Application Support/Claude", "~/Library/Caches/../../Documents",
        "~/Library/Caches/./X", "~/Library/Caches//X", "~/Library/Logs/../Mail", "~/.npm", "Library/Caches/X",
        "~/Library/Developer/CoreSimulator/Devices",
        "~/Library/CachesFalsa/X", "~/Library/LogsFalsi",
    ])
    func forbiddenRoots(root: String) {
        let rule = CleaningRule(id: "x", title: "t", explanation: "e", level: .safe, roots: [root])
        #expect(throws: RuleError.self) { try RuleCatalog(rules: [rule]) }
    }

    @Test("Un catalogo con una regola non valida viene rifiutato per intero")
    func invalidCatalog() throws {
        let json = #"{"version":1,"rules":[{"id":"a","title":"t","explanation":"e","level":"safe","roots":["~/Documents"],"ownerProcesses":[]}]}"#
        #expect(throws: RuleError.rootNotAllowed(rule: "a", root: "~/Documents")) {
            try RuleCatalog(json: Data(json.utf8))
        }
    }

    @Test("Due regole con lo stesso identificativo vengono rifiutate")
    func duplicateIDs() {
        let rule = CleaningRule(id: "x", title: "t", explanation: "e", level: .safe, roots: ["~/Library/Caches/X"])
        #expect(throws: RuleError.duplicateID("x")) { try RuleCatalog(rules: [rule, rule]) }
    }

    @Test("Il piano esclude le voci solo nel cloud, le cartelle illeggibili e i volumi montati")
    func plannerSkipsUnreadable() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova/chiusa")
        try home.file("Library/Caches/Prova/f")
        #expect(chmod(home.at("Library/Caches/Prova/chiusa"), 0) == 0)
        defer { chmod(home.at("Library/Caches/Prova/chiusa"), 0o755) }

        let plan = try await home.plan(cacheRule)

        #expect(plan.roots[0].items.map(\.relativePath) == ["f"])
    }

    @Test("Una cartella vuota non produce candidati")
    func emptyRoot() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova")
        let tree = try await FileScanner().scan(root: home.path).tree
        let catalog = try RuleCatalog(rules: [cacheRule])

        #expect(CleanupPlanner.candidates(tree: tree, home: home.path, homeInTree: "", catalog: catalog).isEmpty)
    }
}

@Suite("Comandi")
struct CommandTests {
    private let erase = CleaningRule(
        id: "simulators.eraseall", title: "t", explanation: "e", level: .review, section: .developer,
        roots: ["~/Library/Developer/CoreSimulator/Devices"], ownerProcesses: ["Simulator"],
        command: CleanupCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "erase", "all"])
    )

    /// Records what would run, and runs nothing.
    private final class Recorder: Sendable {
        let calls = Mutex<[[String]]>([])
        let status: Int32?

        init(status: Int32? = 0) { self.status = status }

        @Sendable func run(_ executable: String, _ arguments: [String], _ timeout: Duration) -> CommandOutcome {
            calls.withLock { $0.append([executable] + arguments) }
            return CommandOutcome(status: status, output: "uscita del comando")
        }
    }

    private func executor(_ home: FakeHome, _ recorder: Recorder, running: Set<String> = []) -> CleanupExecutor {
        CleanupExecutor(
            home: home.path,
            volumePath: "/System/Volumes/Data",
            runningProcesses: { running },
            runCommand: recorder.run
        )
    }

    @Test("I comandi fuori dalla lista chiusa vengono rifiutati", arguments: [
        CleanupCommand(executable: "/bin/rm", arguments: ["-rf", "/"]),
        CleanupCommand(executable: "/bin/sh", arguments: ["-c", "xcrun simctl erase all"]),
        CleanupCommand(executable: "xcrun", arguments: ["simctl", "erase", "all"]),
        CleanupCommand(executable: "/tmp/xcrun", arguments: ["simctl", "erase", "all"]),
        CleanupCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "erase", "all", "; rm -rf ~"]),
        CleanupCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "all"]),
        CleanupCommand(executable: "/opt/homebrew/bin/brew", arguments: ["uninstall", "--force", "git"]),
    ])
    func forbiddenCommands(command: CleanupCommand) {
        let rule = CleaningRule(id: "x", title: "t", explanation: "e", level: .review, roots: ["~/Library/Caches/X"], command: command)
        #expect(throws: RuleError.commandNotAllowed(rule: "x")) { try RuleCatalog(rules: [rule]) }
    }

    @Test("La cartella dei simulatori è ammessa solo per un comando, mai per eliminare file")
    func devicesAreCommandOnly() {
        let direct = CleaningRule(id: "x", title: "t", explanation: "e", level: .review, roots: ["~/Library/Developer/CoreSimulator/Devices"])
        #expect(throws: RuleError.rootNotAllowed(rule: "x", root: "~/Library/Developer/CoreSimulator/Devices")) {
            try RuleCatalog(rules: [direct])
        }
        #expect(throws: Never.self) { try RuleCatalog(rules: [erase]) }
    }

    @Test("Le cartelle dello sviluppatore non ammesse vengono rifiutate", arguments: [
        "~/Library/Developer", "~/Library/Developer/Xcode", "~/Library/Developer/Xcode/Archives",
        "~/Library/Developer/CoreSimulator", "~/Library/Developer/Xcode/DerivedData/../Archives",
    ])
    func forbiddenDeveloperRoots(root: String) {
        let rule = CleaningRule(id: "x", title: "t", explanation: "e", level: .review, roots: [root])
        #expect(throws: RuleError.self) { try RuleCatalog(rules: [rule]) }
    }

    @Test("Un comando esegue esattamente quanto approvato")
    func runsExactCommand() async {
        let home = try! FakeHome()
        let recorder = Recorder()
        let plan = CleanupCandidate(rule: erase, roots: [], commandEstimate: 1_000)

        let report = await executor(home, recorder).run([plan])

        #expect(recorder.calls.withLock { $0 } == [["/usr/bin/xcrun", "simctl", "erase", "all"]])
        #expect(report.rules[0].removedItems == ["xcrun simctl erase all"])
        #expect(report.issueCount == 0)
    }

    @Test("Con l'app proprietaria aperta il comando non parte")
    func blockedByOwner() async {
        let home = try! FakeHome()
        let recorder = Recorder()
        let plan = CleanupCandidate(rule: erase, roots: [], commandEstimate: 1_000)

        let report = await executor(home, recorder, running: ["Simulator"]).run([plan])

        #expect(recorder.calls.withLock { $0 }.isEmpty)
        #expect(report.rules[0].blockedBy == ["Simulator"])
    }

    @Test("Un comando costruito a mano fuori dalla lista non parte")
    func handBuiltCommandIsRefused() async {
        let home = try! FakeHome()
        let recorder = Recorder()
        let bad = CleaningRule(
            id: "x", title: "t", explanation: "e", level: .safe, roots: ["~/Library/Caches/X"],
            command: CleanupCommand(executable: "/bin/rm", arguments: ["-rf", "/"])
        )

        let report = await executor(home, recorder).run([CleanupCandidate(rule: bad, roots: [], commandEstimate: 1)])

        #expect(recorder.calls.withLock { $0 }.isEmpty)
        #expect(report.issueCount == 1)
        #expect(report.removedItemCount == 0)
    }

    @Test("Un piano con comando e file insieme viene rifiutato")
    func commandWithFilesIsRefused() async throws {
        let home = try FakeHome()
        try home.folder("Library/Developer/CoreSimulator/Devices")
        try home.file("Library/Developer/CoreSimulator/Devices/f")
        let recorder = Recorder()
        let plan = CleanupCandidate(
            rule: erase,
            roots: [PlanRoot(path: home.at("Library/Developer/CoreSimulator/Devices"), fileID: 1, items: [
                PlanItem(relativePath: "f", fileID: 1, allocated: 1, privateBytes: 1),
            ])],
            commandEstimate: 1
        )

        let report = await executor(home, recorder).run([plan])

        #expect(recorder.calls.withLock { $0 }.isEmpty)
        #expect(home.exists("Library/Developer/CoreSimulator/Devices/f"))
        #expect(report.issueCount == 1)
    }

    @Test("Un comando fallito è riportato con il suo esito", arguments: [Int32?.some(70), nil])
    func failedCommand(status: Int32?) async {
        let home = try! FakeHome()
        let plan = CleanupCandidate(rule: erase, roots: [], commandEstimate: 1)

        let report = await executor(home, Recorder(status: status)).run([plan])

        #expect(report.removedItemCount == 0)
        #expect(report.rules[0].issues.first?.problem == .commandFailed(status: status, output: "uscita del comando"))
    }

    @Test("L'annullamento impedisce di avviare il comando")
    func cancelBeforeCommand() async {
        let home = try! FakeHome()
        let recorder = Recorder()
        let executor = executor(home, recorder)
        executor.cancel()

        let report = await executor.run([CleanupCandidate(rule: erase, roots: [], commandEstimate: 1)])

        #expect(report.wasCancelled)
        #expect(recorder.calls.withLock { $0 }.isEmpty)
    }

    @Test("Il piano include un comando solo se ha qualcosa da fare")
    func plannerNeedsEstimate() async throws {
        let home = try FakeHome()
        try home.folder("Library")
        let tree = try await FileScanner().scan(root: home.path).tree
        let catalog = try RuleCatalog(rules: [erase])

        #expect(CleanupPlanner.candidates(tree: tree, home: home.path, homeInTree: "", catalog: catalog).isEmpty)

        let found = CleanupPlanner.candidates(
            tree: tree, home: home.path, homeInTree: "", catalog: catalog,
            commandEstimates: [erase.id: 5_000]
        )
        #expect(found.first?.allocated == 5_000)
        #expect(found.first?.privateBytes == 0)
        #expect(found.first?.itemCount == 1)
    }

    @Test("Il catalogo incluso usa solo comandi in lista e non seleziona la cancellazione dei simulatori")
    func builtInCommands() throws {
        let rules = try RuleCatalog.builtIn().rules
        let eraseRule = try #require(rules.first { $0.id == "simulators.eraseall" })

        #expect(eraseRule.level == .review)
        #expect(eraseRule.ownerProcesses == ["Simulator"])
        #expect(rules.filter { $0.command != nil }.count == 3)
    }

    @Test("La stima di brew si legge dalla sua uscita", arguments: [
        ("==> This operation would free approximately 454.1MB of disk space.", Int64(454_100_000)),
        ("==> This operation would free approximately 1.5GB of disk space.", Int64(1_500_000_000)),
        ("==> This operation would free approximately 12KB of disk space.", Int64(12_000)),
    ])
    func brewOutput(text: String, expected: Int64) {
        #expect(DeveloperProbes.brewEstimate(fromOutput: text) == expected)
    }

    @Test("Senza riga di stima, brew non ha nulla da liberare")
    func brewNothingToDo() {
        #expect(DeveloperProbes.brewEstimate(fromOutput: "Warning: niente da fare") == nil)
    }

    @Test("L'elenco dei simulatori non disponibili si legge dal JSON")
    func unavailableList() {
        let json = #"{"devices":{"r1":[{"udid":"B","name":"x"},{"udid":"A","name":"y"}],"r2":[]}}"#
        #expect(DeveloperProbes.unavailableDeviceIDs(fromJSON: json) == ["A", "B"])
        #expect(DeveloperProbes.unavailableDeviceIDs(fromJSON: "non json").isEmpty)
    }

    @Test("Le versioni vecchie di brew escludono quanto copre già la regola della cache")
    func brewBeyondCache() throws {
        let catalog = try RuleCatalog(rules: [CleaningRule(
            id: "homebrew.oldversions", title: "t", explanation: "e", level: .review,
            roots: ["~/Library/Caches/Homebrew"],
            command: CleanupCommand(executable: "/opt/homebrew/bin/brew", arguments: ["cleanup", "--prune=all"])
        )])
        func estimates(cache: Int64) -> [String: Int64] {
            DeveloperProbes.commandEstimates(catalog: catalog, sizeAtHomePath: { _ in cache }, run: { _, _, _ in
                CommandOutcome(status: 0, output: "would free approximately 500MB of disk space")
            })
        }
        // Serve brew installato: altrimenti la regola non si applica e il test non dice nulla.
        try #require(FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew"))

        #expect(estimates(cache: 500_000_000).isEmpty)
        #expect(estimates(cache: 100_000_000) == ["homebrew.oldversions": 400_000_000])
    }

    @Test("Il runner riporta l'esito di un programma vero")
    func runnerReportsStatus() {
        #expect(CommandRunner.run(executable: "/usr/bin/true", arguments: [], timeout: .seconds(5)).status == 0)
        #expect(CommandRunner.run(executable: "/usr/bin/false", arguments: [], timeout: .seconds(5)).status == 1)
        #expect(CommandRunner.run(executable: "/percorso/inesistente", arguments: [], timeout: .seconds(5)).status == nil)
    }

    @Test("Il runner non interpreta gli argomenti come una shell")
    func noShell() {
        let outcome = CommandRunner.run(executable: "/bin/echo", arguments: ["$HOME; rm -rf /"], timeout: .seconds(5))
        #expect(outcome.output.trimmingCharacters(in: .newlines) == "$HOME; rm -rf /")
    }

    @Test("Il runner ferma un comando che supera il tempo")
    func timeout() {
        let start = ContinuousClock.now
        let outcome = CommandRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(200))
        #expect(outcome.status == nil)
        #expect(start.duration(to: .now) < .seconds(5))
    }

    @Test("Il runner regge un'uscita molto lunga senza bloccarsi")
    func longOutput() {
        let outcome = CommandRunner.run(executable: "/usr/bin/yes", arguments: [], timeout: .milliseconds(300))
        #expect(outcome.status == nil)
        #expect(outcome.output.utf8.count <= 256 * 1024)
    }
}

@Suite("Cronologia")
struct HistoryTests {
    private func report(id: UUID = UUID(), freed: Int64) -> CleanupReport {
        CleanupReport(id: id, date: .now, rules: [], measuredFreed: freed, wasCancelled: false)
    }

    @Test("Le voci si accumulano, la più recente per prima")
    func appendAndLoad() throws {
        let home = try FakeHome()
        let history = CleanupHistory(file: URL(fileURLWithPath: home.at("sotto/storia.jsonl")))

        #expect(history.load().isEmpty)
        try history.append(report(freed: 1))
        try history.append(report(freed: 2))

        #expect(history.load().map(\.measuredFreed) == [2, 1])
    }

    @Test("Una riga danneggiata costa solo quella voce")
    func damagedLine() throws {
        let home = try FakeHome()
        let url = URL(fileURLWithPath: home.at("storia.jsonl"))
        let history = CleanupHistory(file: url)
        try history.append(report(freed: 1))

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{non valido\n".utf8))
        try handle.close()
        try history.append(report(freed: 2))

        #expect(history.load().map(\.measuredFreed) == [2, 1])
    }

    @Test("Un'eliminazione reale produce una voce completa")
    func roundTrip() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Prova")
        try home.file("Library/Caches/Prova/f")
        let history = CleanupHistory(file: URL(fileURLWithPath: home.at("storia.jsonl")))

        try history.append(await home.executor().run([try await home.plan(cacheRule)]))

        let saved = try #require(history.load().first)
        #expect(saved.rules[0].removedItems == [home.at("Library/Caches/Prova/f")])
        #expect(saved.rules[0].ruleID == "test.cache")
    }
}

@Suite("Processi")
struct ProcessTests {
    @Test("L'elenco dei processi contiene launchd")
    func listsProcesses() {
        #expect(RunningProcesses.names().contains("launchd"))
    }
}

@Suite("Percorsi reali, in sola lettura")
struct RealPathTests {
    /// The real home goes through firmlinks. Opening without following links must still
    /// work there, or the app could never clean anything. Nothing is removed.
    @Test("La cartella Library reale si apre senza seguire link")
    func realHomeOpens() throws {
        let path = NSHomeDirectory() + "/Library"
        guard case .success(let descriptor) = SafeRemover.openDirectory(atAbsolutePath: path) else {
            Issue.record("impossibile aprire \(path)")
            return
        }
        close(descriptor)
    }

    @Test("Il percorso con /tmp, che è un link simbolico, viene rifiutato")
    func systemSymlinkIsRefused() {
        guard case .failure(let problem) = SafeRemover.openDirectory(atAbsolutePath: "/tmp") else {
            Issue.record("/tmp è stato seguito")
            return
        }
        #expect(problem == .symbolicLinkInPath)
    }
}

private func runTool(_ path: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw POSIXError(.EIO) }
}

extension FakeHome {
    /// Builds a plan by hand for a root that doesn't exist on disk yet.
    func plan(_ rule: CleaningRule, ifExists: Bool, stub name: String) async throws -> CleanupCandidate {
        CleanupCandidate(rule: rule, roots: [
            PlanRoot(path: at("Library/Caches/Prova"), fileID: 1, items: [
                PlanItem(relativePath: name, fileID: 1, allocated: 1, privateBytes: 1),
            ]),
        ])
    }
}
