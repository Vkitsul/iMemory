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
    title: "Sample cache",
    explanation: "",
    level: .safe,
    roots: ["~/Library/Caches/Sample"]
)

private func firstIssue(_ report: CleanupReport) -> RemovalProblem? {
    report.rules.first?.issues.first?.problem
}

@Suite("Removal: normal path")
struct RemovalTests {
    @Test("Deletes the contents and keeps the folder")
    func removesContentsKeepsRoot() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample/sub/deeper")
        try home.file("Library/Caches/Sample/a")
        try home.file("Library/Caches/Sample/sub/b")
        try home.file("Library/Caches/Sample/sub/deeper/c")
        try home.file("Library/Caches/Altra")

        let report = await home.executor().run([try await home.plan(cacheRule)])

        #expect(home.exists("Library/Caches/Sample"))
        #expect(!home.exists("Library/Caches/Sample/a"))
        #expect(!home.exists("Library/Caches/Sample/sub"))
        #expect(home.exists("Library/Caches/Altra"))
        #expect(report.issueCount == 0)
        #expect(report.removedItemCount == 2)
        #expect(report.rules[0].removedBytes >= 30_000)
    }

    @Test("Items that appeared after the scan stay")
    func newEntriesSurvive() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample")
        try home.file("Library/Caches/Sample/old")

        let plan = try await home.plan(cacheRule)
        try home.file("Library/Caches/Sample/new")
        _ = await home.executor().run([plan])

        #expect(!home.exists("Library/Caches/Sample/old"))
        #expect(home.exists("Library/Caches/Sample/new"))
    }

    @Test("Items already gone aren't an error")
    func missingEntryIsFine() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample")
        try home.file("Library/Caches/Sample/f")

        let plan = try await home.plan(cacheRule)
        try FileManager.default.removeItem(atPath: home.at("Library/Caches/Sample/f"))
        let report = await home.executor().run([plan])

        #expect(report.issueCount == 0)
    }

    @Test("The age rule removes only old files, nested ones too")
    func ageRule() async throws {
        let home = try FakeHome()
        try home.folder("Library/Logs/App")
        try home.file("Library/Logs/recent")
        try home.file("Library/Logs/App/old")
        try home.file("Library/Logs/App/recent")
        var times = [timeval(tv_sec: 1_000_000_000, tv_usec: 0), timeval(tv_sec: 1_000_000_000, tv_usec: 0)]
        #expect(utimes(home.at("Library/Logs/App/old"), &times) == 0)

        let rule = CleaningRule(id: "logs", title: "", explanation: "", level: .safe, roots: ["~/Library/Logs"], minimumAgeDays: 30)
        let plan = try await home.plan(rule)
        #expect(plan.itemCount == 1)

        _ = await home.executor().run([plan])

        #expect(!home.exists("Library/Logs/App/old"))
        #expect(home.exists("Library/Logs/App/recent"))
        #expect(home.exists("Library/Logs/recent"))
    }

    @Test("Cancelling stops before the next item")
    func cancellation() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample")
        for index in 0..<5 {
            try home.file("Library/Caches/Sample/f\(index)")
        }
        let plan = try await home.plan(cacheRule)
        let executor = home.executor()
        executor.cancel()

        let report = await executor.run([plan])

        #expect(report.wasCancelled)
        #expect(report.removedItemCount == 0)
        #expect(home.exists("Library/Caches/Sample/f0"))
    }
}

@Suite("Removal: adversarial cases")
struct AdversarialTests {
    @Test("A root that is a symbolic link is refused")
    func rootIsSymlink() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches")
        try home.folder("Documents")
        try home.file("Documents/thesis")
        try home.link("Library/Caches/Sample", to: home.at("Documents"))

        // The plan is built by hand: the scan doesn't follow links, so it wouldn't produce one.
        let plan = CleanupCandidate(rule: cacheRule, roots: [
            PlanRoot(path: home.at("Library/Caches/Sample"), fileID: 1, items: [
                PlanItem(relativePath: "thesis", fileID: 1, allocated: 1, privateBytes: 1),
            ]),
        ])
        let report = await home.executor().run([plan])

        #expect(home.exists("Documents/thesis"))
        #expect(firstIssue(report) == .symbolicLinkInPath)
    }

    @Test("A root replaced by a link after the scan is refused")
    func rootReplacedAfterScan() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample")
        try home.file("Library/Caches/Sample/thesis")
        try home.folder("Documents")
        try home.file("Documents/thesis")

        let plan = try await home.plan(cacheRule)
        try FileManager.default.removeItem(atPath: home.at("Library/Caches/Sample"))
        try home.link("Library/Caches/Sample", to: home.at("Documents"))
        let report = await home.executor().run([plan])

        #expect(home.exists("Documents/thesis"))
        #expect(firstIssue(report) == .symbolicLinkInPath)
    }

    @Test("A symbolic link in the middle of the path is refused")
    func symlinkInAncestor() async throws {
        let home = try FakeHome()
        try home.folder("Elsewhere/Caches/Sample")
        try home.file("Elsewhere/Caches/Sample/f")
        try home.folder("Library")

        let plan = try await home.plan(CleaningRule(
            id: "x", title: "", explanation: "", level: .safe, roots: ["~/Library/Caches/Sample"]
        ), ifExists: false, stub: "f")
        try home.link("Library/Caches", to: home.at("Elsewhere/Caches"))
        let report = await home.executor().run([plan])

        #expect(home.exists("Elsewhere/Caches/Sample/f"))
        #expect(firstIssue(report) == .symbolicLinkInPath)
    }

    @Test("A symbolic link in the plan removes the link, not its target")
    func symlinkItem() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample")
        try home.folder("Documents")
        try home.file("Documents/thesis")
        try home.link("Library/Caches/Sample/outside", to: home.at("Documents"))

        let report = await home.executor().run([try await home.plan(cacheRule)])

        #expect(!home.exists("Library/Caches/Sample/outside"))
        #expect(home.exists("Documents/thesis"))
        #expect(report.issueCount == 0)
    }

    @Test("A nested symbolic link isn't followed")
    func nestedSymlink() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample/sub/deeper")
        try home.folder("Documents")
        try home.file("Documents/thesis")
        try home.link("Library/Caches/Sample/sub/deeper/outside", to: home.at("Documents"))
        try home.link("Library/Caches/Sample/sub/file-outside", to: home.at("Documents/thesis"))

        _ = await home.executor().run([try await home.plan(cacheRule)])

        #expect(!home.exists("Library/Caches/Sample/sub"))
        #expect(home.exists("Documents/thesis"))
    }

    @Test("A folder replaced by a link after planning isn't followed")
    func directorySwappedForSymlink() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample/data")
        try home.file("Library/Caches/Sample/data/f")
        try home.folder("Documents")
        try home.file("Documents/thesis")

        let plan = try await home.plan(cacheRule)
        try FileManager.default.removeItem(atPath: home.at("Library/Caches/Sample/data"))
        try home.link("Library/Caches/Sample/data", to: home.at("Documents"))
        let report = await home.executor().run([plan])

        #expect(home.exists("Documents/thesis"))
        #expect(firstIssue(report) == .changedSinceScan)
    }

    @Test("A file replaced after the scan isn't removed", arguments: [false, true])
    func fileReplaced(sameSize: Bool) async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample")
        try home.file("Library/Caches/Sample/f")

        let plan = try await home.plan(cacheRule)
        try home.file("Library/Caches/Sample/placeholder")
        try FileManager.default.removeItem(atPath: home.at("Library/Caches/Sample/f"))
        try home.file("Library/Caches/Sample/f", size: sameSize ? 10_000 : 77_000)
        try FileManager.default.removeItem(atPath: home.at("Library/Caches/Sample/placeholder"))
        let report = await home.executor().run([plan])

        #expect(home.exists("Library/Caches/Sample/f"))
        #expect(firstIssue(report) == .changedSinceScan)
    }

    @Test("A root recreated after the scan is refused")
    func rootRecreated() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample")
        try home.file("Library/Caches/Sample/f")

        let plan = try await home.plan(cacheRule)
        try FileManager.default.moveItem(atPath: home.at("Library/Caches/Sample"), toPath: home.at("Library/Caches/Moved"))
        try home.folder("Library/Caches/Sample")
        try home.file("Library/Caches/Sample/f")
        let report = await home.executor().run([plan])

        #expect(home.exists("Library/Caches/Sample/f"))
        #expect(home.exists("Library/Caches/Moved/f"))
        #expect(firstIssue(report) == .changedSinceScan)
    }

    @Test("An item path that leaves its root is refused", arguments: [
        "../outside", "sub/../../outside", "/etc/hosts", "./f", "", "a//b", "..",
    ])
    func itemEscapesRoot(path: String) async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample/sub")
        try home.file("Library/Caches/outside")

        let rootID = try #require(try FileManager.default.attributesOfItem(atPath: home.at("Library/Caches/Sample"))[.systemFileNumber] as? UInt64)
        let plan = CleanupCandidate(rule: cacheRule, roots: [
            PlanRoot(path: home.at("Library/Caches/Sample"), fileID: rootID, items: [
                PlanItem(relativePath: path, fileID: 1, allocated: 1, privateBytes: 1),
            ]),
        ])
        let report = await home.executor().run([plan])

        #expect(home.exists("Library/Caches/outside"))
        #expect(firstIssue(report) == .outsideRoot)
    }

    @Test("A plan with a root the rule doesn't name is refused")
    func rootNotInRule() async throws {
        let home = try FakeHome()
        try home.folder("Documents")
        try home.file("Documents/thesis")
        let attributes = try FileManager.default.attributesOfItem(atPath: home.at("Documents"))
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: home.at("Documents/thesis"))

        let plan = CleanupCandidate(rule: cacheRule, roots: [
            PlanRoot(
                path: home.at("Documents"),
                fileID: try #require(attributes[.systemFileNumber] as? UInt64),
                items: [PlanItem(
                    relativePath: "thesis",
                    fileID: try #require(fileAttributes[.systemFileNumber] as? UInt64),
                    allocated: 1,
                    privateBytes: 1
                )]
            ),
        ])
        let report = await home.executor().run([plan])

        #expect(home.exists("Documents/thesis"))
        #expect(firstIssue(report) == .outsideRoot)
    }

    @Test("A plan with an invalid rule is refused even when built by hand")
    func invalidRuleInPlan() async throws {
        let home = try FakeHome()
        try home.folder("Documents")
        try home.file("Documents/thesis")
        let attributes = try FileManager.default.attributesOfItem(atPath: home.at("Documents"))
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: home.at("Documents/thesis"))
        let badRule = CleaningRule(id: "bad", title: "", explanation: "", level: .safe, roots: ["~/Documents"])

        let plan = CleanupCandidate(rule: badRule, roots: [
            PlanRoot(
                path: home.at("Documents"),
                fileID: try #require(attributes[.systemFileNumber] as? UInt64),
                items: [PlanItem(
                    relativePath: "thesis",
                    fileID: try #require(fileAttributes[.systemFileNumber] as? UInt64),
                    allocated: 1,
                    privateBytes: 1
                )]
            ),
        ])
        let report = await home.executor().run([plan])

        #expect(home.exists("Documents/thesis"))
        #expect(firstIssue(report) == .outsideRoot)
    }

    @Test("The rule touches nothing while its owner app is open")
    func ownerRunning() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample")
        try home.file("Library/Caches/Sample/f")
        let rule = CleaningRule(id: "app", title: "", explanation: "", level: .review, roots: ["~/Library/Caches/Sample"], ownerProcesses: ["Sample App"])

        let plan = try await home.plan(rule)
        let report = await home.executor(running: ["Sample App"]).run([plan])

        #expect(home.exists("Library/Caches/Sample/f"))
        #expect(report.rules[0].blockedBy == ["Sample App"])
        #expect(report.removedItemCount == 0)
    }

    @Test("Removing a hard link doesn't touch the file's other name")
    func hardLinkSurvives() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample")
        try home.folder("Documents")
        try home.file("Documents/thesis")
        try FileManager.default.linkItem(atPath: home.at("Documents/thesis"), toPath: home.at("Library/Caches/Sample/link"))

        let report = await home.executor().run([try await home.plan(cacheRule)])

        #expect(!home.exists("Library/Caches/Sample/link"))
        #expect(home.exists("Documents/thesis"))
        #expect(report.rules[0].removedBytes == 0)
    }

    @Test("An unreadable folder is reported and the rest is removed")
    func unreadableSubfolder() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample/data/locked")
        try home.file("Library/Caches/Sample/data/locked/f")
        try home.file("Library/Caches/Sample/data/open")
        try home.file("Library/Caches/Sample/altro")

        let plan = try await home.plan(cacheRule)
        #expect(chmod(home.at("Library/Caches/Sample/data/locked"), 0) == 0)
        defer { chmod(home.at("Library/Caches/Sample/data/locked"), 0o755) }
        let report = await home.executor().run([plan])

        #expect(!home.exists("Library/Caches/Sample/altro"))
        #expect(!home.exists("Library/Caches/Sample/data/open"))
        #expect(home.exists("Library/Caches/Sample/data/locked/f") || firstIssue(report) != nil)
        #expect(firstIssue(report) == .system(code: EACCES))
    }

    @Test("A protected file is reported and the rest is removed")
    func immutableFile() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample")
        try home.file("Library/Caches/Sample/protected")
        try home.file("Library/Caches/Sample/plain")
        #expect(chflags(home.at("Library/Caches/Sample/protected"), UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(home.at("Library/Caches/Sample/protected"), 0) }

        let report = await home.executor().run([try await home.plan(cacheRule)])

        #expect(home.exists("Library/Caches/Sample/protected"))
        #expect(!home.exists("Library/Caches/Sample/plain"))
        #expect(report.issueCount == 1)
    }

    @Test("A volume mounted inside the folder isn't touched")
    func mountedVolume() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample/data/volume")
        try home.file("Library/Caches/Sample/data/f")
        let image = home.at("disk.dmg")
        try runTool("/usr/bin/hdiutil", ["create", "-size", "5m", "-fs", "APFS", "-volname", "ProvaIMemory", "-quiet", image])
        try runTool("/usr/bin/hdiutil", ["attach", image, "-mountpoint", home.at("Library/Caches/Sample/data/volume"), "-nobrowse", "-quiet"])
        defer { try? runTool("/usr/bin/hdiutil", ["detach", home.at("Library/Caches/Sample/data/volume"), "-force", "-quiet"]) }
        try home.file("Library/Caches/Sample/data/volume/inside")

        let report = await home.executor().run([try await home.plan(cacheRule)])

        #expect(home.exists("Library/Caches/Sample/data/volume/inside"))
        #expect(!home.exists("Library/Caches/Sample/data/f"))
        #expect(firstIssue(report) == .otherVolume)
    }

    @Test("Paths beyond PATH_MAX are removed")
    func deepPath() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample")
        let component = String(repeating: "p", count: 200)
        var descriptor = open(home.at("Library/Caches/Sample"), O_RDONLY | O_DIRECTORY)
        for _ in 0..<30 {
            #expect(mkdirat(descriptor, component, 0o755) == 0)
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY)
            close(descriptor)
            descriptor = next
        }
        close(openat(descriptor, "at-the-bottom", O_CREAT | O_WRONLY, 0o644))
        close(descriptor)

        let report = await home.executor().run([try await home.plan(cacheRule)])

        #expect(report.issueCount == 0)
        #expect(!home.exists("Library/Caches/Sample/" + component))
    }
}

@Suite("Measured space", .serialized)
struct MeasuredSpaceTests {
    /// Every test that compares against what the volume reports belongs in this suite:
    /// run side by side, they write hundreds of MB and falsify each other's figures.
    @Test("The recovery estimate matches the space really freed", arguments: [true, false])
    func estimateMatchesRealDeletion(cloneInside: Bool) throws {
        // Other apps write to the disk too, so a single reading can be off. A wrong estimate
        // fails every attempt, while outside noise doesn't last for three in a row.
        var attempts: [String] = []
        for _ in 0..<3 {
            let home = try FakeHome()
            try home.folder("app")
            try home.file("app/a", size: 100_000_000)
            try home.file("app/plain", size: 50_000_000)
            #expect(clonefile(home.at("app/a"), home.at(cloneInside ? "app/b" : "outside"), 0) == 0)

            let estimate = RecoveryEstimator.estimate(paths: [home.at("app")])
            #expect(estimate.recoverable >= (cloneInside ? 149_000_000 : 49_000_000))
            #expect(estimate.recoverable <= (cloneInside ? 151_000_000 : 51_000_000))

            let before = try VolumeCapacity(path: "/System/Volumes/Data").volumeUsed
            try FileManager.default.removeItem(atPath: home.at("app"))
            let freed = before - (try VolumeCapacity(path: "/System/Volumes/Data").volumeUsed)

            if abs(Double(freed - estimate.recoverable)) <= 10_000_000 { return }
            attempts.append("freed \(freed), estimated \(estimate.recoverable)")
        }
        Issue.record("never within 10 MB: \(attempts)")
    }

    @Test("The volume is read once before and once after, without waiting")
    func readsVolumeOnlyTwice() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample")
        try home.file("Library/Caches/Sample/f")
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

    @Test("The two figures diverge only beyond the margin")
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
    @Test("The measured space is within 5% of the expected")
    func measuredMatchesExpected() async throws {
        // As above: outside noise doesn't last for three attempts, a real error does.
        var attempts: [String] = []
        for _ in 0..<3 {
            let home = try FakeHome()
            try home.folder("Library/Caches/Sample")
            for index in 0..<4 {
                try home.file("Library/Caches/Sample/f\(index)", size: 100_000_000)
            }
            let plan = try await home.plan(cacheRule)
            let report = await home.executor().run([plan])

            let expected = Double(report.expectedAllocated)
            #expect(expected >= 400_000_000)
            // The file figure doesn't depend on other apps, so it must always match.
            #expect(abs(Double(report.rules[0].removedBytes) - expected) <= expected * 0.01)

            if abs(Double(report.measuredFreed) - expected) <= expected * 0.05 { return }
            attempts.append("measured \(report.measuredFreed), expected \(report.expectedAllocated)")
        }
        Issue.record("never within 5%: \(attempts)")
    }

    @Test("Deleting a clone frees little, and the private estimate predicts it")
    func cloneFreesLittle() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample")
        try home.folder("Elsewhere")
        try home.file("Elsewhere/original", size: 200_000_000)
        #expect(clonefile(home.at("Elsewhere/original"), home.at("Library/Caches/Sample/clone"), 0) == 0)

        let plan = try await home.plan(cacheRule)
        #expect(plan.allocated >= 200_000_000)
        #expect(plan.privateBytes < 1_000_000)

        let report = await home.executor().run([plan])

        #expect(home.exists("Elsewhere/original"))
        #expect(report.measuredFreed < 20_000_000, "measured \(report.measuredFreed)")
    }
}

@Suite("Rules")
struct RuleTests {
    @Test("The built-in catalog is valid")
    func builtInCatalog() throws {
        let catalog = try RuleCatalog.builtIn()
        #expect(!catalog.rules.isEmpty)
        for rule in catalog.rules {
            #expect(!rule.title.isEmpty && !rule.explanation.isEmpty)
        }
    }

    @Test("Forbidden roots are refused", arguments: [
        "~", "~/", "/", "/System", "/Applications", "/Users", "~/Documents", "~/Desktop", "~/Downloads",
        "~/Pictures", "~/Library", "~/Library/Caches", "~/Library/Application Support",
        "~/Library/Application Support/Claude", "~/Library/Caches/../../Documents",
        "~/Library/Caches/./X", "~/Library/Caches//X", "~/Library/Logs/../Mail", "~/.npm", "Library/Caches/X",
        "~/Library/Developer/CoreSimulator/Devices",
        "~/Library/CachesFake/X", "~/Library/LogsFake",
    ])
    func forbiddenRoots(root: String) {
        let rule = CleaningRule(id: "x", title: "t", explanation: "e", level: .safe, roots: [root])
        #expect(throws: RuleError.self) { try RuleCatalog(rules: [rule]) }
    }

    @Test("A catalog with an invalid rule is refused as a whole")
    func invalidCatalog() throws {
        let json = #"{"version":1,"rules":[{"id":"a","title":"t","explanation":"e","level":"safe","roots":["~/Documents"],"ownerProcesses":[]}]}"#
        #expect(throws: RuleError.rootNotAllowed(rule: "a", root: "~/Documents")) {
            try RuleCatalog(json: Data(json.utf8))
        }
    }

    @Test("Two rules with the same identifier are refused")
    func duplicateIDs() {
        let rule = CleaningRule(id: "x", title: "t", explanation: "e", level: .safe, roots: ["~/Library/Caches/X"])
        #expect(throws: RuleError.duplicateID("x")) { try RuleCatalog(rules: [rule, rule]) }
    }

    @Test("The plan leaves out cloud-only items, unreadable folders, and mounted volumes")
    func plannerSkipsUnreadable() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample/locked")
        try home.file("Library/Caches/Sample/f")
        #expect(chmod(home.at("Library/Caches/Sample/locked"), 0) == 0)
        defer { chmod(home.at("Library/Caches/Sample/locked"), 0o755) }

        let plan = try await home.plan(cacheRule)

        #expect(plan.roots[0].items.map(\.relativePath) == ["f"])
    }

    @Test("An empty folder produces no candidates")
    func emptyRoot() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample")
        let tree = try await FileScanner().scan(root: home.path).tree
        let catalog = try RuleCatalog(rules: [cacheRule])

        #expect(CleanupPlanner.candidates(tree: tree, home: home.path, homeInTree: "", catalog: catalog).isEmpty)
    }
}

@Suite("Commands")
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
            return CommandOutcome(status: status, output: "command output")
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

    @Test("Commands outside the closed list are refused", arguments: [
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

    @Test("The simulators folder is allowed only for a command, never for deleting files")
    func devicesAreCommandOnly() {
        let direct = CleaningRule(id: "x", title: "t", explanation: "e", level: .review, roots: ["~/Library/Developer/CoreSimulator/Devices"])
        #expect(throws: RuleError.rootNotAllowed(rule: "x", root: "~/Library/Developer/CoreSimulator/Devices")) {
            try RuleCatalog(rules: [direct])
        }
        #expect(throws: Never.self) { try RuleCatalog(rules: [erase]) }
    }

    @Test("Developer folders that aren't allowed are refused", arguments: [
        "~/Library/Developer", "~/Library/Developer/Xcode", "~/Library/Developer/Xcode/Archives",
        "~/Library/Developer/CoreSimulator", "~/Library/Developer/Xcode/DerivedData/../Archives",
    ])
    func forbiddenDeveloperRoots(root: String) {
        let rule = CleaningRule(id: "x", title: "t", explanation: "e", level: .review, roots: [root])
        #expect(throws: RuleError.self) { try RuleCatalog(rules: [rule]) }
    }

    @Test("A command runs exactly what was approved")
    func runsExactCommand() async {
        let home = try! FakeHome()
        let recorder = Recorder()
        let plan = CleanupCandidate(rule: erase, roots: [], commandEstimate: 1_000)

        let report = await executor(home, recorder).run([plan])

        #expect(recorder.calls.withLock { $0 } == [["/usr/bin/xcrun", "simctl", "erase", "all"]])
        #expect(report.rules[0].removedItems == ["xcrun simctl erase all"])
        #expect(report.issueCount == 0)
    }

    @Test("The command doesn't start while its owner app is open")
    func blockedByOwner() async {
        let home = try! FakeHome()
        let recorder = Recorder()
        let plan = CleanupCandidate(rule: erase, roots: [], commandEstimate: 1_000)

        let report = await executor(home, recorder, running: ["Simulator"]).run([plan])

        #expect(recorder.calls.withLock { $0 }.isEmpty)
        #expect(report.rules[0].blockedBy == ["Simulator"])
    }

    @Test("A hand-built command outside the list doesn't start")
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

    @Test("A plan with both a command and files is refused")
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

    @Test("A failed command is reported with its status", arguments: [Int32?.some(70), nil])
    func failedCommand(status: Int32?) async {
        let home = try! FakeHome()
        let plan = CleanupCandidate(rule: erase, roots: [], commandEstimate: 1)

        let report = await executor(home, Recorder(status: status)).run([plan])

        #expect(report.removedItemCount == 0)
        #expect(report.rules[0].issues.first?.problem == .commandFailed(status: status, output: "command output"))
    }

    @Test("Cancelling prevents the command from starting")
    func cancelBeforeCommand() async {
        let home = try! FakeHome()
        let recorder = Recorder()
        let executor = executor(home, recorder)
        executor.cancel()

        let report = await executor.run([CleanupCandidate(rule: erase, roots: [], commandEstimate: 1)])

        #expect(report.wasCancelled)
        #expect(recorder.calls.withLock { $0 }.isEmpty)
    }

    @Test("The plan includes a command only when it has work to do")
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

    @Test("The built-in catalog uses only listed commands and doesn't select erasing simulators")
    func builtInCommands() throws {
        let rules = try RuleCatalog.builtIn().rules
        let eraseRule = try #require(rules.first { $0.id == "simulators.eraseall" })

        #expect(eraseRule.level == .review)
        #expect(eraseRule.ownerProcesses == ["Simulator"])
        #expect(rules.filter { $0.command != nil }.count == 3)
    }

    @Test("brew's estimate is read from its output", arguments: [
        ("==> This operation would free approximately 454.1MB of disk space.", Int64(454_100_000)),
        ("==> This operation would free approximately 1.5GB of disk space.", Int64(1_500_000_000)),
        ("==> This operation would free approximately 12KB of disk space.", Int64(12_000)),
    ])
    func brewOutput(text: String, expected: Int64) {
        #expect(DeveloperProbes.brewEstimate(fromOutput: text) == expected)
    }

    @Test("Without an estimate line, brew has nothing to free")
    func brewNothingToDo() {
        #expect(DeveloperProbes.brewEstimate(fromOutput: "Warning: nothing to do") == nil)
    }

    @Test("The list of unavailable simulators is read from JSON")
    func unavailableList() {
        let json = #"{"devices":{"r1":[{"udid":"B","name":"x"},{"udid":"A","name":"y"}],"r2":[]}}"#
        #expect(DeveloperProbes.unavailableDeviceIDs(fromJSON: json) == ["A", "B"])
        #expect(DeveloperProbes.unavailableDeviceIDs(fromJSON: "not json").isEmpty)
    }

    @Test("Old brew versions exclude what the cache rule already covers")
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
        // Needs brew installed: otherwise the rule doesn't apply and the test says nothing.
        try #require(FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew"))

        #expect(estimates(cache: 500_000_000).isEmpty)
        #expect(estimates(cache: 100_000_000) == ["homebrew.oldversions": 400_000_000])
    }

    @Test("The runner reports a real program's status")
    func runnerReportsStatus() {
        #expect(CommandRunner.run(executable: "/usr/bin/true", arguments: [], timeout: .seconds(5)).status == 0)
        #expect(CommandRunner.run(executable: "/usr/bin/false", arguments: [], timeout: .seconds(5)).status == 1)
        #expect(CommandRunner.run(executable: "/percorso/inesistente", arguments: [], timeout: .seconds(5)).status == nil)
    }

    @Test("The runner doesn't interpret arguments like a shell")
    func noShell() {
        let outcome = CommandRunner.run(executable: "/bin/echo", arguments: ["$HOME; rm -rf /"], timeout: .seconds(5))
        #expect(outcome.output.trimmingCharacters(in: .newlines) == "$HOME; rm -rf /")
    }

    @Test("The runner stops a command that runs out of time")
    func timeout() {
        let start = ContinuousClock.now
        let outcome = CommandRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(200))
        #expect(outcome.status == nil)
        #expect(start.duration(to: .now) < .seconds(5))
    }

    @Test("The runner copes with very long output without blocking")
    func longOutput() {
        let outcome = CommandRunner.run(executable: "/usr/bin/yes", arguments: [], timeout: .milliseconds(300))
        #expect(outcome.status == nil)
        #expect(outcome.output.utf8.count <= 256 * 1024)
    }
}

@Suite("History")
struct HistoryTests {
    private func report(id: UUID = UUID(), freed: Int64) -> CleanupReport {
        CleanupReport(id: id, date: .now, rules: [], measuredFreed: freed, wasCancelled: false)
    }

    @Test("Entries add up, most recent first")
    func appendAndLoad() throws {
        let home = try FakeHome()
        let history = CleanupHistory(file: URL(fileURLWithPath: home.at("sub/history.jsonl")))

        #expect(history.load().isEmpty)
        try history.append(report(freed: 1))
        try history.append(report(freed: 2))

        #expect(history.load().map(\.measuredFreed) == [2, 1])
    }

    @Test("A damaged line costs only that entry")
    func damagedLine() throws {
        let home = try FakeHome()
        let url = URL(fileURLWithPath: home.at("history.jsonl"))
        let history = CleanupHistory(file: url)
        try history.append(report(freed: 1))

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not valid\n".utf8))
        try handle.close()
        try history.append(report(freed: 2))

        #expect(history.load().map(\.measuredFreed) == [2, 1])
    }

    @Test("A real removal produces a complete entry")
    func roundTrip() async throws {
        let home = try FakeHome()
        try home.folder("Library/Caches/Sample")
        try home.file("Library/Caches/Sample/f")
        let history = CleanupHistory(file: URL(fileURLWithPath: home.at("history.jsonl")))

        try history.append(await home.executor().run([try await home.plan(cacheRule)]))

        let saved = try #require(history.load().first)
        #expect(saved.rules[0].removedItems == [home.at("Library/Caches/Sample/f")])
        #expect(saved.rules[0].ruleID == "test.cache")
    }
}

@Suite("Processes")
struct ProcessTests {
    @Test("The process list contains launchd")
    func listsProcesses() {
        #expect(RunningProcesses.names().contains("launchd"))
    }
}

@Suite("Real paths, read-only")
struct RealPathTests {
    /// The real home goes through firmlinks. Opening without following links must still
    /// work there, or the app could never clean anything. Nothing is removed.
    @Test("The real Library folder opens without following links")
    func realHomeOpens() throws {
        let path = NSHomeDirectory() + "/Library"
        guard case .success(let descriptor) = SafeRemover.openDirectory(atAbsolutePath: path) else {
            Issue.record("could not open \(path)")
            return
        }
        close(descriptor)
    }

    @Test("A path through /tmp, which is a symbolic link, is refused")
    func systemSymlinkIsRefused() {
        guard case .failure(let problem) = SafeRemover.openDirectory(atAbsolutePath: "/tmp") else {
            Issue.record("/tmp was followed")
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
            PlanRoot(path: at("Library/Caches/Sample"), fileID: 1, items: [
                PlanItem(relativePath: name, fileID: 1, allocated: 1, privateBytes: 1),
            ]),
        ])
    }
}
