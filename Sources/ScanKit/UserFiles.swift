import Foundation

/// Finds the files in a home that are the user's own to pick one by one.
public enum UserFiles {
    /// Folders treated as a single document. Files inside must not be picked one by one:
    /// removing one damages the whole.
    private static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "kext", "plugin", "xpc",
        "photoslibrary", "photoboothlibrary", "musiclibrary", "tvlibrary", "imovielibrary",
        "fcpbundle", "theater", "aplibrary", "lrdata", "lrcat-data",
        "xcodeproj", "xcworkspace", "playground", "pages", "numbers", "key", "rtfd",
        "pkg", "mpkg", "sparsebundle", "dmgpart",
    ]

    /// Calls `visit` for each regular file of at least `minimumBytes` in the home. Skips
    /// `~/Library`, hidden files and folders such as `.git`, packages, and files that live
    /// only in the cloud.
    public static func forEach(
        in tree: FileTree,
        homeInTree: String,
        realRoot: String,
        minimumBytes: Int64,
        visit: (_ node: NodeID, _ path: String) -> Void
    ) {
        guard let home = tree.node(atRelativePath: homeInTree) else { return }
        var stack: [(node: NodeID, path: String)] = [(home, realRoot + "/" + homeInTree)]

        while let (folder, path) = stack.popLast() {
            for child in tree.children(of: folder) {
                // Children are sorted by size, so nothing below this one can qualify.
                guard tree.sizes(of: child).allocated >= minimumBytes else { break }

                let name = tree.name(of: child)
                let flags = tree.flags(of: child)
                guard !name.hasPrefix("."),
                      flags.isDisjoint(with: [.dataless, .hardLinkDuplicate, .mountPoint, .excluded])
                else { continue }
                if folder == home, name == "Library" { continue }

                let childPath = path + "/" + name
                switch tree.kind(of: child) {
                case .directory:
                    if !packageExtensions.contains((name as NSString).pathExtension.lowercased()) {
                        stack.append((child, childPath))
                    }
                case .file:
                    visit(child, childPath)
                case .symlink, .other:
                    break
                }
            }
        }
    }
}

/// Decides when to warn about low disk space. Warns once when space falls below the
/// threshold, and again only after it has recovered, so it never nags.
public struct SpaceWatch: Equatable, Sendable {
    public var threshold: Int64
    private var hasWarned = false

    public init(threshold: Int64) {
        self.threshold = threshold
    }

    public func isLow(free: Int64) -> Bool {
        free < threshold
    }

    /// Returns true when this reading should trigger a warning.
    public mutating func shouldWarn(free: Int64) -> Bool {
        if free < threshold {
            defer { hasWarned = true }
            return !hasWarned
        }
        // A margin above the threshold keeps a value hovering around it from warning repeatedly.
        if free >= threshold + threshold / 10 {
            hasWarned = false
        }
        return false
    }
}
