import Darwin
import Foundation

/// A personal item to move to the Trash, recorded as it was when scanned.
public struct TrashItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case app, leftover, file
    }

    public let path: String
    public let fileID: UInt64
    public let allocated: Int64
    public let kind: Kind

    public var id: String { path }

    public init(path: String, fileID: UInt64, allocated: Int64, kind: Kind) {
        self.path = path
        self.fileID = fileID
        self.allocated = allocated
        self.kind = kind
    }
}

/// Decides which paths may go to the Trash. As with `RootPolicy`, this is a strict list in
/// code, and the Trash being recoverable is a second line of defence, not the first.
public struct TrashPolicy: Sendable {
    let home: String
    let appFolders: [String]

    /// In `~/Library`, only a direct child of one of these can be a leftover.
    private static let leftoverFolders: Set<String> = [
        "Application Support", "Caches", "Containers", "Cookies", "Group Containers",
        "HTTPStorages", "LaunchAgents", "Logs", "Preferences", "Saved Application State", "WebKit",
    ]

    /// Folders treated as documents, inside which nothing may be picked on its own.
    private static let packageSuffixes = [".app", ".photoslibrary", ".photoboothlibrary", ".framework", ".bundle"]

    public init(home: String, appFolders: [String]) {
        self.home = home
        self.appFolders = appFolders
    }

    public func allows(_ item: TrashItem) -> Bool {
        let components = item.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard item.path.hasPrefix("/"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }

        switch item.kind {
        case .app:
            guard item.path.hasSuffix(".app"), !item.path.dropLast(4).contains(".app/") else { return false }
            return appFolders.contains { folder in
                guard item.path.hasPrefix(folder + "/") else { return false }
                return item.path.dropFirst(folder.count + 1).split(separator: "/").count <= 2
            }

        case .leftover:
            let prefix = home + "/Library/"
            guard item.path.hasPrefix(prefix) else { return false }
            let inner = item.path.dropFirst(prefix.count).split(separator: "/")
            return inner.count == 2 && Self.leftoverFolders.contains(String(inner[0]))

        case .file:
            let prefix = home + "/"
            guard item.path.hasPrefix(prefix) else { return false }
            let inner = item.path.dropFirst(prefix.count).split(separator: "/")
            guard let first = inner.first, first != "Library" else { return false }
            guard !inner.contains(where: { $0.hasPrefix(".") }) else { return false }
            // The file itself may have any name. What it's inside must not be a package.
            return !inner.dropLast().contains { part in
                Self.packageSuffixes.contains { part.hasSuffix($0) }
            }
        }
    }
}

/// Moves personal items to the Trash after checking each one against the scan.
public final class TrashMover: Sendable {
    private let policy: TrashPolicy
    private let runningProcesses: @Sendable () -> Set<String>
    private let moveToTrash: @Sendable (URL) throws -> Void

    public init(
        policy: TrashPolicy,
        runningProcesses: @escaping @Sendable () -> Set<String> = RunningProcesses.names,
        moveToTrash: @escaping @Sendable (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.policy = policy
        self.runningProcesses = runningProcesses
        self.moveToTrash = moveToTrash
    }

    /// - Parameters:
    ///   - title: How the operation appears in the report and the history.
    ///   - executable: The app's executable, if this removes an app. Nothing moves while it runs.
    ///   - mustRemain: Copies that have to stay, for duplicates. If any is gone or different,
    ///     nothing moves: the items might be the last copies left.
    @concurrent
    public func run(
        title: String,
        items: [TrashItem],
        executable: String? = nil,
        mustRemain: [TrashItem] = []
    ) async -> CleanupReport {
        var result = RuleResult(
            ruleID: "cestino",
            title: title,
            expectedAllocated: items.map(\.allocated).reduce(0, +),
            expectedPrivate: 0
        )
        var report = CleanupReport(id: UUID(), date: .now, rules: [], measuredFreed: 0, wasCancelled: false)
        report.movedToTrash = true

        if let executable, RunningProcesses.contains(executable, in: runningProcesses()) {
            result.blockedBy = [executable]
            report.rules = [result]
            return report
        }

        let moving = Set(items.map(\.path))
        for survivor in mustRemain where moving.contains(survivor.path) || check(survivor) != nil {
            result.issues.append(RuleResult.Issue(path: survivor.path, problem: .copyToKeepChanged))
        }
        guard result.issues.isEmpty else {
            report.rules = [result]
            return report
        }

        for item in items {
            if let problem = check(item) {
                // Already gone means there is nothing left to do.
                if problem != .system(code: ENOENT) {
                    result.issues.append(RuleResult.Issue(path: item.path, problem: problem))
                }
                continue
            }
            do {
                try moveToTrash(URL(fileURLWithPath: item.path))
                result.removedItems.append(item.path)
                result.removedBytes += item.allocated
            } catch {
                result.issues.append(RuleResult.Issue(
                    path: item.path,
                    problem: .trashFailed(message: error.localizedDescription)
                ))
            }
        }
        report.rules = [result]
        return report
    }

    /// Reports why an item must stay, or `nil` if it can go.
    private func check(_ item: TrashItem) -> RemovalProblem? {
        guard policy.allows(item) else { return .outsideRoot }

        let url = URL(fileURLWithPath: item.path)
        let parentPath = url.deletingLastPathComponent().path
        let parent: Int32
        switch SafeRemover.openDirectory(atAbsolutePath: parentPath) {
        case .failure(let problem): return problem
        case .success(let descriptor): parent = descriptor
        }
        defer { close(parent) }

        var info = stat()
        guard fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return .system(code: errno)
        }
        guard info.st_ino == item.fileID else { return .changedSinceScan }

        let type = info.st_mode & S_IFMT
        switch item.kind {
        case .app:
            return type == S_IFDIR ? nil : .changedSinceScan
        case .file:
            return type == S_IFREG ? nil : .changedSinceScan
        case .leftover:
            return type == S_IFDIR || type == S_IFREG ? nil : .symbolicLinkInPath
        }
    }
}
