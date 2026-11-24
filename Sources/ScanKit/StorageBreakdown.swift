/// Splits the disk into categories that don't overlap and add up to its capacity.
public struct StorageBreakdown: Sendable {
    public enum Kind: Hashable, Sendable {
        case applications
        case appData
        case photos
        case iPhoneBackups
        case developer
        case caches
        case userFiles
        case systemData
        case unattributed
        case otherVolumes
    }

    public struct Entry: Identifiable, Sendable {
        public let kind: Kind
        public let bytes: Int64
        /// The folder to open for this category, when a single one represents it.
        public let node: NodeID?

        public var id: Kind { kind }
    }

    public let total: Int64
    public let free: Int64
    /// Largest first. Categories with nothing in them are left out.
    public let entries: [Entry]

    /// - Parameters:
    ///   - homePath: The user's home, relative to the scan root.
    ///   - volumeUsed: Space the scanned volume reports as used.
    public init(tree: FileTree, homePath: String, total: Int64, free: Int64, volumeUsed: Int64) {
        func located(_ path: String) -> (node: NodeID?, bytes: Int64) {
            let node = tree.node(atRelativePath: path)
            return (node, node.map { tree.sizes(of: $0).allocated } ?? 0)
        }

        let applications = located("Applications")
        let home = located(homePath)
        let library = located(homePath + "/Library")
        let pictures = located(homePath + "/Pictures")
        let backups = located(homePath + "/Library/Application Support/MobileSync")
        let developer = located(homePath + "/Library/Developer")
        let caches = located(homePath + "/Library/Caches")
        let measured = tree.sizes(of: tree.root).allocated

        let entries: [Entry] = [
            Entry(kind: .applications, bytes: applications.bytes, node: applications.node),
            Entry(
                kind: .appData,
                bytes: max(0, library.bytes - backups.bytes - developer.bytes - caches.bytes),
                node: library.node
            ),
            Entry(kind: .photos, bytes: pictures.bytes, node: pictures.node),
            Entry(kind: .iPhoneBackups, bytes: backups.bytes, node: backups.node),
            Entry(kind: .developer, bytes: developer.bytes, node: developer.node),
            Entry(kind: .caches, bytes: caches.bytes, node: caches.node),
            Entry(kind: .userFiles, bytes: max(0, home.bytes - library.bytes - pictures.bytes), node: home.node),
            Entry(
                kind: .systemData,
                bytes: max(0, measured - applications.bytes - home.bytes),
                node: tree.root
            ),
            Entry(kind: .unattributed, bytes: max(0, volumeUsed - measured), node: nil),
            Entry(kind: .otherVolumes, bytes: max(0, total - free - volumeUsed), node: nil),
        ]

        self.total = total
        self.free = free
        self.entries = entries.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    }
}
