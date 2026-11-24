import CleanKit
import Foundation
import Observation
import RulesKit
import Synchronization

/// What the Cleanup section shows, from choosing what to remove to the final report.
@Observable
final class CleanupModel {
    enum Phase {
        case choosing
        case confirming
        case running(CleanupProgress)
        case finished(CleanupReport)
    }

    private(set) var candidates: [CleanupCandidate] = []
    private(set) var runningProcesses = Set<String>()
    private(set) var history: [CleanupReport]
    var selectedIDs = Set<String>()
    var phase = Phase.choosing
    /// The screen in use. A cleanup acts only on what that screen shows as selected.
    var activeSection = RuleSection.general

    /// Called when the user closes the report, since the disk has changed.
    var onFinished: () -> Void = {}

    private let home: String
    private let historyFile: CleanupHistory
    private var executor: CleanupExecutor?

    /// Adds a Trash operation, which runs elsewhere, to the same history.
    func record(_ report: CleanupReport) {
        try? historyFile.append(report)
        history = historyFile.load()
    }

    /// - Parameters:
    ///   - home: The home that rules apply to. Only the self-check passes another one.
    init(
        home: String = NSHomeDirectory(),
        historyFile: URL = AppStorage.folder.appendingPathComponent("cronologia.jsonl")
    ) {
        self.home = home
        self.historyFile = CleanupHistory(file: historyFile)
        history = self.historyFile.load()
    }

    /// Takes the plan from a new scan. Only safe rules start selected.
    func update(candidates: [CleanupCandidate]) {
        self.candidates = candidates
        selectedIDs = Set(candidates.filter { $0.rule.level == .safe }.map(\.id))
        refreshRunningProcesses()
    }

    func refreshRunningProcesses() {
        runningProcesses = RunningProcesses.names()
    }

    func blockingProcesses(of candidate: CleanupCandidate) -> [String] {
        candidate.rule.ownerProcesses.filter { RunningProcesses.contains($0, in: runningProcesses) }
    }

    /// What would actually run: selected, and with no owner app open.
    var selectedCandidates: [CleanupCandidate] {
        candidates.filter {
            $0.rule.resolvedSection == activeSection
                && selectedIDs.contains($0.id)
                && blockingProcesses(of: $0).isEmpty
        }
    }

    var isPresentingSheet: Bool {
        if case .choosing = phase { false } else { true }
    }

    func confirm() {
        let plan = selectedCandidates
        guard !plan.isEmpty else {
            phase = .choosing
            return
        }

        let executor = CleanupExecutor(home: home, volumePath: AppModel.scanRoot)
        self.executor = executor
        let start = CleanupProgress(completedItems: 0, totalItems: plan.map(\.itemCount).reduce(0, +))
        phase = .running(start)

        Task {
            let latest = LatestProgress(start)
            let poll = Task {
                while !Task.isCancelled {
                    phase = .running(latest.value)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let report = await executor.run(plan) { latest.value = $0 }
            poll.cancel()

            try? historyFile.append(report)
            history = historyFile.load()
            phase = .finished(report)
        }
    }

    /// Runs without confirmation, on what `ScheduledCleanup.eligible` allows, and without
    /// touching the screens: the user may be looking at something else.
    func runScheduled(_ candidates: [CleanupCandidate]) async -> CleanupReport {
        let executor = CleanupExecutor(home: home, volumePath: AppModel.scanRoot)
        var report = await executor.run(ScheduledCleanup.eligible(candidates))
        report.wasScheduled = true
        record(report)
        return report
    }

    func cancelRun() {
        executor?.cancel()
    }

    func closeReport() {
        phase = .choosing
        onFinished()
    }
}

/// Lets the removal, on another thread, report progress that the UI reads at its own pace.
private nonisolated final class LatestProgress: Sendable {
    private let storage: Mutex<CleanupProgress>

    init(_ initial: CleanupProgress) {
        storage = Mutex(initial)
    }

    var value: CleanupProgress {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

enum AppStorage {
    /// The app's own folder, the only place it writes apart from what a cleanup removes.
    nonisolated static let folder = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/iMemory")
}

extension RemovalProblem {
    var message: String {
        switch self {
        case .outsideRoot: "Fuori dalle cartelle ammesse dalla regola"
        case .symbolicLinkInPath: "Nel percorso c'è un link simbolico"
        case .changedSinceScan: "Cambiato dopo la scansione"
        case .otherVolume: "Qui è montato un altro volume"
        case .system(let code): String(cString: strerror(code))
        case .copyToKeepChanged:
            "La copia da tenere è sparita o cambiata, quindi non è stato spostato nulla."
        case .trashFailed(let message):
            "Non è stato possibile spostarlo nel Cestino. Se appartiene al sistema o ad App Store, spostalo dal Finder. \(message)"
        case .commandFailed(let status, let output):
            status.map { "Il comando è terminato con errore \($0). \(output)" }
                ?? "Il comando non è partito o non è finito in tempo. \(output)"
        }
    }
}
