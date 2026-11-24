import CryptoKit
import Darwin
import Foundation
import ScanKit

public struct DuplicateFile: Identifiable, Equatable, Sendable {
    public let path: String
    public let fileID: UInt64
    public let allocated: Int64
    public let modified: Date
    /// Shares its space with another file in the group, so removing it frees nothing
    /// unless the other goes too.
    public let isClone: Bool

    public var id: String { path }
}

/// Files with the same content that really occupy space more than once.
public struct DuplicateGroup: Identifiable, Equatable, Sendable {
    public let digest: String
    public let files: [DuplicateFile]
    /// Separate copies on disk. Clones of each other count as one.
    public let copies: Int
    /// What keeping a single copy would give back.
    public let reclaimable: Int64

    public var id: String { digest }
}

public struct DuplicateProgress: Equatable, Sendable {
    public let filesRead: Int
    public let filesToRead: Int
    public let bytesRead: Int64

    public init(filesRead: Int, filesToRead: Int, bytesRead: Int64) {
        self.filesRead = filesRead
        self.filesToRead = filesToRead
        self.bytesRead = bytesRead
    }
}

public struct DuplicateSearchResult: Equatable, Sendable {
    public let groups: [DuplicateGroup]
    public let filesConsidered: Int
    /// Files that couldn't be read, so they might have duplicates not shown.
    public let unreadableFiles: Int
    public let wasCancelled: Bool
}

/// Finds files with identical content, in three steps of rising cost: same size, then
/// same start and end, then the whole content. Only reads, and only what it has to.
public enum DuplicateFinder {
    private static let partialBytes = 64 * 1024
    private static let chunkBytes = 1024 * 1024

    private struct Candidate {
        let path: String
        let node: NodeID
        let size: Int64
    }

    /// Blocks while it reads, so call it away from the main actor.
    public static func find(
        tree: FileTree,
        homeInTree: String,
        realRoot: String,
        minimumBytes: Int64 = 1_000_000,
        progress: (DuplicateProgress) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) -> DuplicateSearchResult {
        // Reading a file that lives only in the cloud must not download it.
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previous >= 0 {
                setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
            }
        }

        var bySize: [Int64: [Candidate]] = [:]
        var considered = 0
        UserFiles.forEach(in: tree, homeInTree: homeInTree, realRoot: realRoot, minimumBytes: minimumBytes) { node, path in
            let size = tree.sizes(of: node).logical
            guard size > 0 else { return }
            considered += 1
            bySize[size, default: []].append(Candidate(path: path, node: node, size: size))
        }

        var unreadable = 0
        var bytesRead: Int64 = 0
        var filesRead = 0

        // Two files of the same size that are the same clone need no reading at all.
        let sameSize = bySize.values.filter { $0.count > 1 }
        let filesToRead = sameSize.map(\.count).reduce(0, +)

        var groups: [DuplicateGroup] = []
        for candidates in sameSize {
            if isCancelled() {
                return result(groups, considered, unreadable, cancelled: true)
            }

            var byPartial: [String: [Candidate]] = [:]
            for candidate in candidates {
                if let digest = partialDigest(of: candidate.path, size: candidate.size, bytesRead: &bytesRead) {
                    byPartial[digest, default: []].append(candidate)
                } else {
                    unreadable += 1
                }
                filesRead += 1
                progress(DuplicateProgress(filesRead: filesRead, filesToRead: filesToRead, bytesRead: bytesRead))
            }

            for sharing in byPartial.values where sharing.count > 1 {
                var byFull: [String: [Candidate]] = [:]
                for candidate in sharing {
                    if isCancelled() {
                        return result(groups, considered, unreadable, cancelled: true)
                    }
                    if let digest = fullDigest(of: candidate.path, bytesRead: &bytesRead, isCancelled: isCancelled) {
                        byFull[digest, default: []].append(candidate)
                    } else if !isCancelled() {
                        unreadable += 1
                    }
                    progress(DuplicateProgress(filesRead: filesRead, filesToRead: filesToRead, bytesRead: bytesRead))
                }
                for (digest, identical) in byFull where identical.count > 1 {
                    if let group = makeGroup(digest: digest, files: identical, tree: tree) {
                        groups.append(group)
                    }
                }
            }
        }
        return result(groups, considered, unreadable, cancelled: false)
    }

    private static func result(_ groups: [DuplicateGroup], _ considered: Int, _ unreadable: Int, cancelled: Bool) -> DuplicateSearchResult {
        DuplicateSearchResult(
            groups: groups.sorted { $0.reclaimable == $1.reclaimable ? $0.digest < $1.digest : $0.reclaimable > $1.reclaimable },
            filesConsidered: considered,
            unreadableFiles: unreadable,
            wasCancelled: cancelled
        )
    }

    /// Builds a group, or nothing if the files are really one copy on disk: clones of each
    /// other aren't wasted space, so they must not appear as duplicates.
    private static func makeGroup(digest: String, files: [Candidate], tree: FileTree) -> DuplicateGroup? {
        var cloneCounts: [UInt64: Int] = [:]
        var described: [(file: Candidate, identity: FileIdentity?)] = []
        for file in files {
            let identity = RecoveryEstimator.identity(ofFileAt: file.path)
            described.append((file, identity))
            if let identity, identity.cloneRefCount > 1 {
                cloneCounts[identity.cloneID, default: 0] += 1
            }
        }

        // Each set of clones sharing space here counts as a single copy.
        var seenClones = Set<UInt64>()
        var copies = 0
        var allocatedPerCopy: Int64 = .max
        for (file, identity) in described {
            let allocated = tree.sizes(of: file.node).allocated
            if let identity, identity.cloneRefCount > 1, (cloneCounts[identity.cloneID] ?? 0) > 1 {
                if seenClones.insert(identity.cloneID).inserted {
                    copies += 1
                    allocatedPerCopy = min(allocatedPerCopy, allocated)
                }
            } else {
                copies += 1
                allocatedPerCopy = min(allocatedPerCopy, allocated)
            }
        }
        guard copies > 1 else { return nil }

        let duplicates = described.map { file, identity in
            let isClone = identity.map { $0.cloneRefCount > 1 && (cloneCounts[$0.cloneID] ?? 0) > 1 } ?? false
            return DuplicateFile(
                path: file.path,
                fileID: tree.fileID(of: file.node),
                allocated: tree.sizes(of: file.node).allocated,
                modified: tree.modificationDate(of: file.node),
                isClone: isClone
            )
        }
        return DuplicateGroup(
            digest: digest,
            files: duplicates.sorted { $0.path < $1.path },
            copies: copies,
            reclaimable: Int64(copies - 1) * allocatedPerCopy
        )
    }

    private static func open(_ path: String) -> Int32? {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        // Reading gigabytes once shouldn't push useful data out of the system's cache.
        _ = fcntl(descriptor, F_NOCACHE, 1)
        return descriptor
    }

    private static func partialDigest(of path: String, size: Int64, bytesRead: inout Int64) -> String? {
        guard let descriptor = open(path) else { return nil }
        defer { close(descriptor) }

        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: partialBytes)
        let head = read(descriptor, &buffer, partialBytes)
        guard head >= 0 else { return nil }
        hash.update(data: buffer[0..<head])
        bytesRead += Int64(head)

        if size > Int64(partialBytes) * 2 {
            let tail = pread(descriptor, &buffer, partialBytes, off_t(size) - off_t(partialBytes))
            guard tail >= 0 else { return nil }
            hash.update(data: buffer[0..<tail])
            bytesRead += Int64(tail)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fullDigest(of path: String, bytesRead: inout Int64, isCancelled: () -> Bool) -> String? {
        guard let descriptor = open(path) else { return nil }
        defer { close(descriptor) }

        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        while true {
            if isCancelled() { return nil }
            let count = read(descriptor, &buffer, chunkBytes)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            hash.update(data: buffer[0..<count])
            bytesRead += Int64(count)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// What to send to the Trash from a selection in the results, keeping at least one copy.
public struct DuplicateSelection: Equatable, Sendable {
    public let toRemove: [DuplicateFile]
    /// One file from each affected group, which must still be there when the others go.
    public let toKeep: [DuplicateFile]

    public enum SelectionError: Error, Equatable {
        /// Every file of a group is selected, which would leave no copy.
        case wouldRemoveEveryCopy(digest: String)
    }

    public init(groups: [DuplicateGroup], selected: Set<String>) throws {
        var remove: [DuplicateFile] = []
        var keep: [DuplicateFile] = []
        for group in groups {
            let chosen = group.files.filter { selected.contains($0.id) }
            guard !chosen.isEmpty else { continue }
            guard let survivor = group.files.first(where: { !selected.contains($0.id) }) else {
                throw SelectionError.wouldRemoveEveryCopy(digest: group.digest)
            }
            remove += chosen
            keep.append(survivor)
        }
        toRemove = remove
        toKeep = keep
    }
}
