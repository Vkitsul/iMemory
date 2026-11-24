import AppsKit
import CleanKit
import Foundation
import Observation
import RulesKit
import ScanKit

/// Everything computed from a finished scan.
struct ScanSession {
    let tree: FileTree
    let statistics: ScanStatistics
    let duration: Duration
    let breakdown: StorageBreakdown
    let largestFolders: [NodeID]
    /// Folders in the user's home that couldn't be read, which means the app lacks
    /// Full Disk Access. Unreadable system folders are normal and don't count.
    let unreadableInHome: Int
    let candidates: [CleanupCandidate]
    let apps: [InstalledApp]
    let largeFiles: [LargeFile]
    /// What grew since the previous scan, or `nil` if there is nothing to compare with.
    let growth: [ScanSnapshot.Growth]?
    let previousScanDate: Date?

    /// Runs off the main actor because it walks the whole tree.
    @concurrent
    static func make(from result: ScanResult, capacity: VolumeCapacity, homePath: String) async -> ScanSession {
        let tree = result.tree
        let catalog = try? RuleCatalog.builtIn()
        let snapshot = ScanSnapshot(tree: tree, unreadableDirectories: result.statistics.unreadableDirectories)
        let previous = SnapshotStore.exchange(snapshot)
        let estimates = catalog.map { catalog in
            DeveloperProbes.commandEstimates(catalog: catalog) { path in
                tree.node(atRelativePath: homePath + "/" + path).map { tree.sizes(of: $0).allocated } ?? 0
            }
        } ?? [:]

        return ScanSession(
            tree: tree,
            statistics: result.statistics,
            duration: result.duration,
            breakdown: StorageBreakdown(
                tree: tree,
                homePath: homePath,
                total: capacity.total,
                free: capacity.available,
                volumeUsed: capacity.volumeUsed
            ),
            largestFolders: tree.largestDirectories(limit: 12),
            unreadableInHome: tree.node(atRelativePath: homePath).map { tree.unreadableDirectoryCount(under: $0) } ?? 0,
            candidates: catalog.map {
                CleanupPlanner.candidates(
                    tree: tree,
                    home: NSHomeDirectory(),
                    homeInTree: homePath,
                    catalog: $0,
                    commandEstimates: estimates
                )
            } ?? [],
            apps: AppFinder.apps(
                tree: tree,
                appFolders: ["Applications", homePath + "/Applications"],
                homeInTree: homePath,
                realRoot: ""
            ),
            largeFiles: LargeFileFinder.files(tree: tree, homeInTree: homePath, realRoot: ""),
            growth: previous.flatMap { snapshot.growth(since: $0) },
            previousScanDate: previous?.date
        )
    }
}

@Observable
final class AppModel {
    enum Phase {
        case idle
        case scanning(ScanProgress)
        case ready(ScanSession)
        case failed(String)
    }

    enum Section: Hashable {
        case overview, explore, apps, files, duplicates, cleanup, developer, history, automation
    }

    private(set) var phase = Phase.idle
    /// No new items for a while. Usually macOS is waiting for an answer to a permission
    /// prompt, and the scan can't go on until someone replies.
    private(set) var isScanStalled = false
    private(set) var explorer: Explorer?
    var section = Section.overview
    /// Replaced only by the self-check, to run a cleanup against a fake home.
    var cleanup = CleanupModel()
    /// Replaced only by the self-check, to run against a fake home.
    var trash = TrashModel()
    let duplicates = DuplicatesModel()
    let automation: AutomationModel

    private var scanner: FileScanner?
    private let runsAutomation: Bool
    private var automationTask: Task<Void, Never>?
    private var isRunningScheduledCleanup = false
    /// When the current results were scanned, to avoid cleaning from an old plan.
    private var scanFinishedAt: Date?

    /// - Parameter runsAutomation: Off in the self-check, which must never clean by itself.
    init(runsAutomation: Bool = ProcessInfo.processInfo.environment["IMEMORY_SELFCHECK"] == nil) {
        automation = AutomationModel(notifies: runsAutomation)
        self.runsAutomation = runsAutomation
        cleanup.onFinished = { [unowned self] in startScan() }
        trash.onFinished = { [unowned self] report in
            duplicates.reset()
            cleanup.record(report)
            startScan()
        }
    }

    static let scanRoot = "/System/Volumes/Data"

    var isScanning: Bool {
        if case .scanning = phase { true } else { false }
    }

    var session: ScanSession? {
        if case .ready(let session) = phase { session } else { nil }
    }

    func startScan() {
        guard !isScanning else { return }
        let scanner = FileScanner()
        self.scanner = scanner
        phase = .scanning(scanner.progress)
        Task { await run(scanner) }
    }

    /// Keeps free space up to date and runs scheduled cleanups for as long as the app is open.
    func startAutomation() {
        automation.refreshSpace()
        guard runsAutomation, automationTask == nil else { return }
        automationTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                automation.refreshSpace()
                await runScheduledCleanupIfDue()
            }
        }
    }

    private func runScheduledCleanupIfDue() async {
        guard automation.isCleanupDue, !isRunningScheduledCleanup, !isScanning,
              !cleanup.isPresentingSheet, !trash.isPresentingSheet
        else { return }

        // Plans from an old scan would mostly be skipped as changed, so scan first.
        guard let session, let scanned = scanFinishedAt, Date.now.timeIntervalSince(scanned) < 3600 else {
            startScan()
            return
        }

        isRunningScheduledCleanup = true
        defer { isRunningScheduledCleanup = false }
        let report = await cleanup.runScheduled(session.candidates)
        automation.recordScheduledCleanup(report)
        startScan()
    }

    func cancelScan() {
        scanner?.cancel()
    }

    func open(_ node: NodeID) {
        explorer?.show(node)
        section = .explore
    }

    private func run(_ scanner: FileScanner) async {
        let poll = Task {
            var lastItems = -1
            var lastChange = ContinuousClock.now
            while !Task.isCancelled {
                let progress = scanner.progress
                if progress.items != lastItems {
                    lastItems = progress.items
                    lastChange = .now
                }
                isScanStalled = lastChange.duration(to: .now) > .seconds(8)
                phase = .scanning(progress)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer {
            poll.cancel()
            isScanStalled = false
        }

        do {
            let result = try await scanner.scan(root: Self.scanRoot)
            let capacity = try VolumeCapacity(path: Self.scanRoot)
            let homePath = String(NSHomeDirectory().drop { $0 == "/" })
            let session = await ScanSession.make(from: result, capacity: capacity, homePath: homePath)
            poll.cancel()
            explorer = Explorer(tree: session.tree)
            duplicates.reset()
            scanFinishedAt = .now
            cleanup.update(candidates: session.candidates)
            phase = .ready(session)
        } catch is CancellationError {
            poll.cancel()
            phase = .idle
        } catch ScanError.rootUnavailable(let path, let code) {
            poll.cancel()
            phase = .failed("\(path): \(String(cString: strerror(code)))")
        } catch {
            poll.cancel()
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Keeps the folder sizes of the last scan between launches.
private enum SnapshotStore {
    nonisolated private static let file = AppStorage.folder.appendingPathComponent("ultima-scansione.json")

    /// Saves `snapshot` and returns the one it replaces.
    nonisolated static func exchange(_ snapshot: ScanSnapshot) -> ScanSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let previous = (try? Data(contentsOf: file)).flatMap { try? decoder.decode(ScanSnapshot.self, from: $0) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return previous
    }
}
