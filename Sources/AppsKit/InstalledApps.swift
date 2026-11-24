import CoreServices
import Foundation
import ScanKit

/// Something an app left in the Library, which goes with it if the user agrees.
public struct Leftover: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Recreated if the app comes back. Selected by default.
        case cache
        /// Settings. Selected by default: useless without the app.
        case settings
        /// May hold the user's work. Never selected by default.
        case data
    }

    public let path: String
    public let fileID: UInt64
    public let allocated: Int64
    public let kind: Kind
    /// Found by exact bundle identifier. Otherwise only the name matched, so another app
    /// could own it, and it is never selected by default whatever its kind.
    public let matchedByIdentifier: Bool

    public var id: String { path }
    public var isSelectedByDefault: Bool { matchedByIdentifier && kind != .data }
}

public struct InstalledApp: Identifiable, Equatable, Sendable {
    public let path: String
    public let fileID: UInt64
    public let name: String
    public let bundleIdentifier: String
    public let version: String?
    public let executable: String?
    public let allocated: Int64
    public let privateBytes: Int64
    /// `nil` means unknown: Spotlight often has no record, which is not the same as never.
    public let lastUsed: Date?
    public let leftovers: [Leftover]
    public let isFromAppStore: Bool

    public var id: String { path }
    public var leftoversSize: Int64 { leftovers.map(\.allocated).reduce(0, +) }
}

public enum AppFinder {
    /// Where in `~/Library` an app keeps things, with `%` standing for the identifier.
    private static let identifierPlaces: [(pattern: String, kind: Leftover.Kind)] = [
        ("Caches/%", .cache),
        ("HTTPStorages/%", .cache),
        ("WebKit/%", .cache),
        ("Saved Application State/%.savedState", .cache),
        ("Logs/%", .cache),
        ("Cookies/%.binarycookies", .settings),
        ("Preferences/%.plist", .settings),
        ("LaunchAgents/%.plist", .settings),
        ("Application Support/%", .data),
        ("Containers/%", .data),
    ]

    /// Places where a folder named like the app probably belongs to it.
    private static let namePlaces: [(folder: String, kind: Leftover.Kind)] = [
        ("Application Support", .data),
        ("Caches", .cache),
        ("Logs", .cache),
    ]

    /// Finds apps in a scan.
    ///
    /// - Parameters:
    ///   - appFolders: Folders to look in, relative to the scan root. One level of
    ///     subfolders is searched too, for `Utilities` and the like.
    ///   - homeInTree: The home, relative to the scan root.
    ///   - realRoot: What to put before a path in the tree to get a real one, since the
    ///     scan root is not the path the user knows.
    /// - Returns: Apps, largest first.
    public static func apps(
        tree: FileTree,
        appFolders: [String],
        homeInTree: String,
        realRoot: String,
        lastUsed: (String) -> Date? = spotlightLastUsed
    ) -> [InstalledApp] {
        var found: [InstalledApp] = []

        for folder in appFolders {
            guard let node = tree.node(atRelativePath: folder) else { continue }
            for child in tree.children(of: node) where tree.kind(of: child) == .directory {
                let name = tree.name(of: child)
                if name.hasSuffix(".app") {
                    if let app = makeApp(child, relative: folder + "/" + name, tree: tree, homeInTree: homeInTree, realRoot: realRoot, lastUsed: lastUsed) {
                        found.append(app)
                    }
                } else if !name.hasPrefix(".") {
                    for grandchild in tree.children(of: child) where tree.kind(of: grandchild) == .directory {
                        let inner = tree.name(of: grandchild)
                        guard inner.hasSuffix(".app") else { continue }
                        if let app = makeApp(grandchild, relative: folder + "/" + name + "/" + inner, tree: tree, homeInTree: homeInTree, realRoot: realRoot, lastUsed: lastUsed) {
                            found.append(app)
                        }
                    }
                }
            }
        }
        return found.sorted { $0.allocated + $0.leftoversSize > $1.allocated + $1.leftoversSize }
    }

    private static func makeApp(
        _ node: NodeID,
        relative: String,
        tree: FileTree,
        homeInTree: String,
        realRoot: String,
        lastUsed: (String) -> Date?
    ) -> InstalledApp? {
        let path = realRoot + "/" + relative
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path + "/Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty
        else { return nil }

        let fileName = String(tree.name(of: node).dropLast(4))
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? fileName
        let sizes = tree.sizes(of: node)

        return InstalledApp(
            path: path,
            fileID: tree.fileID(of: node),
            name: name,
            bundleIdentifier: identifier,
            version: info["CFBundleShortVersionString"] as? String,
            executable: info["CFBundleExecutable"] as? String,
            allocated: sizes.allocated,
            privateBytes: sizes.privateBytes,
            lastUsed: lastUsed(path),
            leftovers: leftovers(identifier: identifier, names: Set([name, fileName]), tree: tree, homeInTree: homeInTree, realRoot: realRoot),
            isFromAppStore: FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt")
        )
    }

    private static func leftovers(
        identifier: String,
        names: Set<String>,
        tree: FileTree,
        homeInTree: String,
        realRoot: String
    ) -> [Leftover] {
        var result: [Leftover] = []
        var seen = Set<String>()

        func add(_ relative: String, kind: Leftover.Kind, byIdentifier: Bool) {
            let inTree = homeInTree + "/Library/" + relative
            guard !seen.contains(inTree), let node = tree.node(atRelativePath: inTree) else { return }
            seen.insert(inTree)
            result.append(Leftover(
                path: realRoot + "/" + inTree,
                fileID: tree.fileID(of: node),
                allocated: tree.sizes(of: node).allocated,
                kind: kind,
                matchedByIdentifier: byIdentifier
            ))
        }

        for place in identifierPlaces {
            add(place.pattern.replacingOccurrences(of: "%", with: identifier), kind: place.kind, byIdentifier: true)
        }

        // Group containers are named with a team prefix: `TEAMID.com.example.app`.
        if let groups = tree.node(atRelativePath: homeInTree + "/Library/Group Containers") {
            for child in tree.children(of: groups) where tree.name(of: child).hasSuffix("." + identifier) {
                add("Group Containers/" + tree.name(of: child), kind: .data, byIdentifier: true)
            }
        }

        // A very short name could easily belong to something else.
        for name in names where name.count >= 4 {
            for place in namePlaces {
                add(place.folder + "/" + name, kind: place.kind, byIdentifier: false)
            }
        }
        return result.sorted { $0.allocated > $1.allocated }
    }

    @Sendable
    public static func spotlightLastUsed(path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

public struct LargeFile: Identifiable, Equatable, Sendable {
    public enum Category: Equatable, Sendable {
        case installer, archive, video, other
    }

    public let path: String
    public let fileID: UInt64
    public let allocated: Int64
    public let privateBytes: Int64
    public let modified: Date
    public let category: Category

    public var id: String { path }
}

public enum LargeFileFinder {
    private static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "ipa", "apk", "exe", "msi"]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "mkv", "avi", "m4v", "webm", "wmv"]

    /// Regular files in the home, outside places where a file isn't the user's to pick:
    /// `~/Library`, hidden folders such as `.git`, and packages.
    /// - Returns: The largest files, largest first.
    public static func files(
        tree: FileTree,
        homeInTree: String,
        realRoot: String,
        minimumBytes: Int64 = 100_000_000,
        limit: Int = 300
    ) -> [LargeFile] {
        var found: [LargeFile] = []
        UserFiles.forEach(in: tree, homeInTree: homeInTree, realRoot: realRoot, minimumBytes: minimumBytes) { node, path in
            let sizes = tree.sizes(of: node)
            found.append(LargeFile(
                path: path,
                fileID: tree.fileID(of: node),
                allocated: sizes.allocated,
                privateBytes: sizes.privateBytes,
                modified: tree.modificationDate(of: node),
                category: category(forExtension: (path as NSString).pathExtension.lowercased())
            ))
        }
        return Array(found.sorted { $0.allocated > $1.allocated }.prefix(limit))
    }

    private static func category(forExtension fileExtension: String) -> LargeFile.Category {
        if installerExtensions.contains(fileExtension) { return .installer }
        if archiveExtensions.contains(fileExtension) { return .archive }
        if videoExtensions.contains(fileExtension) { return .video }
        return .other
    }
}
