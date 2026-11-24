import Foundation

/// Folder sizes from one scan, kept so a later scan can show what grew.
public struct ScanSnapshot: Codable, Sendable, Equatable {
    public let date: Date
    public let unreadableDirectories: Int
    /// Allocated bytes by path relative to the scan root.
    public let folders: [String: Int64]

    public init(date: Date, unreadableDirectories: Int, folders: [String: Int64]) {
        self.date = date
        self.unreadableDirectories = unreadableDirectories
        self.folders = folders
    }

    /// Records folders big enough to matter, to keep the file small.
    public init(tree: FileTree, unreadableDirectories: Int, date: Date = .now, maximumDepth: Int = 6, minimumBytes: Int64 = 20_000_000) {
        var folders: [String: Int64] = [:]
        var stack: [(node: NodeID, path: String, depth: Int)] = [(tree.root, "", 0)]

        while let (node, path, depth) = stack.popLast() {
            if depth > 0 {
                folders[path] = tree.sizes(of: node).allocated
            }
            guard depth < maximumDepth else { continue }
            for child in tree.children(of: node) {
                let size = tree.sizes(of: child).allocated
                // Children are sorted by size, so nothing after this one qualifies.
                guard size >= minimumBytes else { break }
                if tree.kind(of: child) == .directory {
                    let name = tree.name(of: child)
                    stack.append((child, path.isEmpty ? name : path + "/" + name, depth + 1))
                }
            }
        }

        self.init(date: date, unreadableDirectories: unreadableDirectories, folders: folders)
    }

    public struct Growth: Identifiable, Equatable, Sendable {
        public let path: String
        public let bytes: Int64
        public let added: Int64

        public var id: String { path }
    }

    /// What grew since `previous`, largest first, or `nil` if the two can't be compared.
    ///
    /// Scans with different permissions aren't comparable: granting Full Disk Access
    /// makes gigabytes appear that were there all along. A parent is left out when one
    /// of its subfolders explains most of its growth, since the subfolder is the answer.
    public func growth(since previous: ScanSnapshot, minimumBytes: Int64 = 100_000_000, limit: Int = 5) -> [Growth]? {
        guard abs(unreadableDirectories - previous.unreadableDirectories) <= 10 else { return nil }

        var grown: [Growth] = []
        for (path, bytes) in folders {
            let added = bytes - (previous.folders[path] ?? 0)
            if added >= minimumBytes {
                grown.append(Growth(path: path, bytes: bytes, added: added))
            }
        }

        let specific = grown.filter { candidate in
            !grown.contains { other in
                other.path.hasPrefix(candidate.path + "/") && Double(other.added) >= Double(candidate.added) * 0.8
            }
        }
        return Array(specific.sorted { $0.added == $1.added ? $0.path < $1.path : $0.added > $1.added }.prefix(limit))
    }
}
