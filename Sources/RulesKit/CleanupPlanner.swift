import Foundation
import ScanKit

/// Something a rule would remove, recorded with enough detail to notice if the disk
/// changes before the removal happens.
public struct PlanItem: Codable, Identifiable, Sendable, Equatable {
    /// Relative to the root. A top-level name, or a nested path for age-based rules.
    public let relativePath: String
    public let fileID: UInt64
    public let allocated: Int64
    public let privateBytes: Int64

    public var id: String { relativePath }

    public init(relativePath: String, fileID: UInt64, allocated: Int64, privateBytes: Int64) {
        self.relativePath = relativePath
        self.fileID = fileID
        self.allocated = allocated
        self.privateBytes = privateBytes
    }
}

public struct PlanRoot: Codable, Sendable, Equatable {
    /// Absolute path, in the form the user knows such as `/Users/name/Library/Caches/X`.
    public let path: String
    public let fileID: UInt64
    public let items: [PlanItem]

    public init(path: String, fileID: UInt64, items: [PlanItem]) {
        self.path = path
        self.fileID = fileID
        self.items = items
    }
}

/// What one rule would remove right now. Immutable: changing the disk means a new scan.
public struct CleanupCandidate: Identifiable, Sendable, Equatable {
    public let rule: CleaningRule
    public let roots: [PlanRoot]
    /// For a rule that runs a command: the most it could free. What it really frees is
    /// up to the tool, so the least is taken to be nothing.
    public let commandEstimate: Int64?

    public init(rule: CleaningRule, roots: [PlanRoot], commandEstimate: Int64? = nil) {
        self.rule = rule
        self.roots = roots
        self.commandEstimate = commandEstimate
    }

    public var id: String { rule.id }
    public var itemCount: Int {
        rule.command != nil ? 1 : roots.map(\.items.count).reduce(0, +)
    }

    /// Most this could free, if nothing is shared with a clone outside the plan.
    public var allocated: Int64 {
        commandEstimate ?? roots.flatMap(\.items).map(\.allocated).reduce(0, +)
    }

    /// Least this will free, since space shared with a clone stays in use.
    public var privateBytes: Int64 {
        rule.command != nil ? 0 : roots.flatMap(\.items).map(\.privateBytes).reduce(0, +)
    }
}

public enum CleanupPlanner {
    /// Finds what each rule would remove in a finished scan. Reads only the tree.
    ///
    /// - Parameters:
    ///   - home: The real home path, used for the paths in the plan.
    ///   - homeInTree: The same folder, relative to the scan root.
    ///   - commandEstimates: What each command rule would free, by rule ID. A command
    ///     rule without an entry has nothing to do and is left out.
    /// - Returns: Candidates with something to remove, largest first.
    public static func candidates(
        tree: FileTree,
        home: String,
        homeInTree: String,
        catalog: RuleCatalog,
        commandEstimates: [String: Int64] = [:],
        now: Date = .now
    ) -> [CleanupCandidate] {
        var result: [CleanupCandidate] = []

        for rule in catalog.rules {
            if rule.command != nil {
                if let estimate = commandEstimates[rule.id] {
                    result.append(CleanupCandidate(rule: rule, roots: [], commandEstimate: estimate))
                }
                continue
            }

            var roots: [PlanRoot] = []
            for root in rule.roots {
                // The catalog is validated when loaded. This keeps the guarantee local.
                guard let relative = try? RootPolicy.validatedRelativePath(of: root, rule: rule.id),
                      let node = tree.node(atRelativePath: homeInTree + "/" + relative),
                      tree.kind(of: node) == .directory
                else { continue }

                let items = rule.minimumAgeDays.map {
                    oldFiles(under: node, tree: tree, olderThanDays: $0, now: now)
                } ?? topLevelItems(of: node, tree: tree)

                if !items.isEmpty {
                    roots.append(PlanRoot(path: home + "/" + relative, fileID: tree.fileID(of: node), items: items))
                }
            }
            if !roots.isEmpty {
                result.append(CleanupCandidate(rule: rule, roots: roots))
            }
        }
        return result.sorted { $0.allocated > $1.allocated }
    }

    /// Things that free nothing or can't be removed safely stay out of the plan.
    private static func isRemovable(_ flags: NodeFlags) -> Bool {
        flags.isDisjoint(with: [.mountPoint, .dataless, .excluded, .unreadable])
    }

    private static func topLevelItems(of root: NodeID, tree: FileTree) -> [PlanItem] {
        tree.children(of: root)
            .filter { isRemovable(tree.flags(of: $0)) }
            .map { item(for: $0, relativePath: tree.name(of: $0), tree: tree) }
    }

    private static func oldFiles(under root: NodeID, tree: FileTree, olderThanDays days: Int, now: Date) -> [PlanItem] {
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        var items: [PlanItem] = []
        var stack: [(node: NodeID, prefix: String)] = [(root, "")]

        while let (folder, prefix) = stack.popLast() {
            for child in tree.children(of: folder) where isRemovable(tree.flags(of: child)) {
                let path = prefix + tree.name(of: child)
                switch tree.kind(of: child) {
                case .directory:
                    stack.append((child, path + "/"))
                case .file where tree.modificationDate(of: child) < limit:
                    items.append(item(for: child, relativePath: path, tree: tree))
                default:
                    break
                }
            }
        }
        return items.sorted { $0.allocated > $1.allocated }
    }

    private static func item(for node: NodeID, relativePath: String, tree: FileTree) -> PlanItem {
        let sizes = tree.sizes(of: node)
        return PlanItem(
            relativePath: relativePath,
            fileID: tree.fileID(of: node),
            allocated: sizes.allocated,
            privateBytes: sizes.privateBytes
        )
    }
}
