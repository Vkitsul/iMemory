import Darwin
import Foundation
import RulesKit
import ScanKit
import Synchronization

public struct RuleResult: Codable, Sendable, Identifiable {
    public struct Issue: Codable, Sendable, Equatable {
        public let path: String
        public let problem: RemovalProblem
    }

    public let ruleID: String
    public let title: String
    public let expectedAllocated: Int64
    public let expectedPrivate: Int64
    /// Sum of what was unlinked. `CleanupReport.measuredFreed` is the figure to trust.
    public var removedBytes: Int64 = 0
    public var removedItems: [String] = []
    public var issues: [Issue] = []
    /// Open apps that stopped this rule from running at all.
    public var blockedBy: [String] = []

    public var id: String { ruleID }
}

public struct CleanupReport: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public var rules: [RuleResult]
    /// What the volume reports, before minus after. Lower, or even negative, if other
    /// apps wrote to the disk meanwhile.
    public var measuredFreed: Int64
    public var wasCancelled: Bool
    /// True if items went to the Trash, which frees nothing until it is emptied. Optional
    /// so that history written before this existed still loads.
    public var movedToTrash: Bool?
    /// True if this ran on a schedule, with no one confirming it.
    public var wasScheduled: Bool?

    public var isTrashOperation: Bool { movedToTrash == true }

    public var expectedAllocated: Int64 { rules.map(\.expectedAllocated).reduce(0, +) }
    public var expectedPrivate: Int64 { rules.map(\.expectedPrivate).reduce(0, +) }
    /// Sum of the files unlinked. Unlike `measuredFreed` other apps can't disturb it, but
    /// it overstates what files sharing space with a clone give back.
    public var removedBytes: Int64 { rules.map(\.removedBytes).reduce(0, +) }

    /// True when the two figures disagree enough to explain to the user.
    public var figuresDiverge: Bool {
        abs(measuredFreed - removedBytes) > max(10_000_000, removedBytes / 20)
    }
    public var removedItemCount: Int { rules.map(\.removedItems.count).reduce(0, +) }
    public var issueCount: Int { rules.map(\.issues.count).reduce(0, +) }
}

public struct CleanupProgress: Equatable, Sendable {
    public let completedItems: Int
    public let totalItems: Int

    public init(completedItems: Int, totalItems: Int) {
        self.completedItems = completedItems
        self.totalItems = totalItems
    }
}

/// The only code in the project that changes the disk.
///
/// Before touching anything, each rule is validated again, its owner apps are checked,
/// and its root is reopened without following links and compared with the scan. Each
/// item is then compared with the scan just before it is removed.
public final class CleanupExecutor: Sendable {
    private static let commandTimeout = Duration.seconds(600)

    private let home: String
    private let volumePath: String
    private let runningProcesses: @Sendable () -> Set<String>
    private let volumeUsed: @Sendable (String) throws -> Int64
    private let runCommand: @Sendable (String, [String], Duration) -> CommandOutcome
    private let cancelled = Atomic<Bool>(false)

    public init(
        home: String,
        volumePath: String,
        runningProcesses: @escaping @Sendable () -> Set<String> = RunningProcesses.names,
        volumeUsed: @escaping @Sendable (String) throws -> Int64 = { try VolumeCapacity(path: $0).volumeUsed },
        runCommand: @escaping @Sendable (String, [String], Duration) -> CommandOutcome = CommandRunner.run
    ) {
        self.home = home
        self.volumePath = volumePath
        self.runningProcesses = runningProcesses
        self.volumeUsed = volumeUsed
        self.runCommand = runCommand
    }

    /// Stops before the next item. What was already removed stays removed.
    public func cancel() {
        cancelled.store(true, ordering: .relaxed)
    }

    @concurrent
    public func run(
        _ candidates: [CleanupCandidate],
        progress: @escaping @Sendable (CleanupProgress) -> Void = { _ in }
    ) async -> CleanupReport {
        // Read right before and right after, with no wait: APFS accounts for freed space at
        // once, while any time spent waiting only lets other apps' writes into the figure.
        let before = try? volumeUsed(volumePath)
        var report = execute(candidates, progress: progress)
        if let before, let after = try? volumeUsed(volumePath) {
            report.measuredFreed = before - after
        }
        return report
    }

    private func execute(
        _ candidates: [CleanupCandidate],
        progress: @Sendable (CleanupProgress) -> Void
    ) -> CleanupReport {
        // Listing a folder that lives only in the cloud must not download it. The call
        // below stays on this thread because nothing in it suspends.
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previous >= 0 {
                setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
            }
        }

        let total = candidates.map(\.itemCount).reduce(0, +)
        var completed = 0
        var report = CleanupReport(id: UUID(), date: .now, rules: [], measuredFreed: 0, wasCancelled: false)

        for candidate in candidates {
            var result = RuleResult(
                ruleID: candidate.rule.id,
                title: candidate.rule.title,
                expectedAllocated: candidate.allocated,
                expectedPrivate: candidate.privateBytes
            )
            defer { report.rules.append(result) }

            let isCandidateValid = validate(candidate, into: &result)
            let running = runningProcesses()
            result.blockedBy = candidate.rule.ownerProcesses.filter { RunningProcesses.contains($0, in: running) }

            guard isCandidateValid, result.blockedBy.isEmpty else {
                completed += candidate.itemCount
                progress(CleanupProgress(completedItems: completed, totalItems: total))
                continue
            }

            if let command = candidate.rule.command {
                if cancelled.load(ordering: .relaxed) || Task.isCancelled {
                    report.wasCancelled = true
                    return report
                }
                let outcome = runCommand(command.executable, command.arguments, Self.commandTimeout)
                if outcome.status == 0 {
                    result.removedItems.append(command.displayText)
                } else {
                    result.issues.append(RuleResult.Issue(
                        path: command.displayText,
                        problem: .commandFailed(status: outcome.status, output: String(outcome.output.suffix(500)))
                    ))
                }
                completed += 1
                progress(CleanupProgress(completedItems: completed, totalItems: total))
                continue
            }

            for root in candidate.roots {
                guard let (descriptor, device) = openRoot(root, into: &result) else {
                    completed += root.items.count
                    progress(CleanupProgress(completedItems: completed, totalItems: total))
                    continue
                }
                defer { close(descriptor) }

                for item in root.items {
                    if cancelled.load(ordering: .relaxed) || Task.isCancelled {
                        report.wasCancelled = true
                        return report
                    }
                    let outcome = SafeRemover.removeItem(
                        relativePath: item.relativePath,
                        expectedFileID: item.fileID,
                        rootDescriptor: descriptor,
                        rootPath: root.path,
                        device: device
                    )
                    result.removedBytes += outcome.freedBytes
                    result.issues += outcome.problems.map { RuleResult.Issue(path: $0.path, problem: $0.problem) }
                    if outcome.problems.isEmpty {
                        result.removedItems.append(root.path + "/" + item.relativePath)
                    }
                    completed += 1
                    progress(CleanupProgress(completedItems: completed, totalItems: total))
                }
            }
        }
        return report
    }

    /// The plan must still describe folders the rule is allowed to touch, under this home.
    private func validate(_ candidate: CleanupCandidate, into result: inout RuleResult) -> Bool {
        do {
            try candidate.rule.validate()
        } catch {
            for root in candidate.roots {
                result.issues.append(RuleResult.Issue(path: root.path, problem: .outsideRoot))
            }
            if let command = candidate.rule.command {
                result.issues.append(RuleResult.Issue(path: command.displayText, problem: .outsideRoot))
            }
            return false
        }
        // A command acts through its tool, so a plan for one must not carry files as well.
        if candidate.rule.command != nil, !candidate.roots.isEmpty {
            for root in candidate.roots {
                result.issues.append(RuleResult.Issue(path: root.path, problem: .outsideRoot))
            }
            return false
        }

        let allowed = Set(candidate.rule.roots.compactMap { root in
            (try? RootPolicy.validatedRelativePath(of: root, rule: candidate.rule.id)).map { home + "/" + $0 }
        })
        let unexpected = candidate.roots.filter { !allowed.contains($0.path) }
        for root in unexpected {
            result.issues.append(RuleResult.Issue(path: root.path, problem: .outsideRoot))
        }
        return unexpected.isEmpty
    }

    private func openRoot(_ root: PlanRoot, into result: inout RuleResult) -> (descriptor: Int32, device: dev_t)? {
        switch SafeRemover.openDirectory(atAbsolutePath: root.path) {
        case .failure(let problem):
            // A root that no longer exists has nothing left to remove.
            if problem != .system(code: ENOENT) {
                result.issues.append(RuleResult.Issue(path: root.path, problem: problem))
            }
            return nil
        case .success(let descriptor):
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                result.issues.append(RuleResult.Issue(path: root.path, problem: .system(code: errno)))
                close(descriptor)
                return nil
            }
            guard info.st_ino == root.fileID else {
                result.issues.append(RuleResult.Issue(path: root.path, problem: .changedSinceScan))
                close(descriptor)
                return nil
            }
            return (descriptor, info.st_dev)
        }
    }
}

public enum RunningProcesses {
    /// Whether an executable is among `names`. The system keeps only the start of a long
    /// process name, so the comparison does the same.
    public static func contains(_ executable: String, in names: Set<String>) -> Bool {
        names.contains(String(executable.prefix(Int(MAXCOMLEN))))
    }

    /// Names of the executables running right now.
    @Sendable
    public static func names() -> Set<String> {
        var request = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&request, 4, nil, &size, nil, 0) == 0 else { return [] }

        // Room for processes started between the two calls.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&request, 4, &processes, &size, nil, 0) == 0 else { return [] }

        var names = Set<String>()
        for index in 0..<(size / MemoryLayout<kinfo_proc>.stride) {
            var process = processes[index]
            let name = withUnsafePointer(to: &process.kp_proc.p_comm) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            names.insert(name)
        }
        return names
    }
}
