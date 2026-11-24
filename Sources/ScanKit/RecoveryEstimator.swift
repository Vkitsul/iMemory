import Darwin

/// How much space removing a set of files would really give back.
public struct RecoveryEstimate: Equatable, Sendable {
    /// What the files occupy, counting shared space in full for each of them.
    public let allocated: Int64
    /// What comes back: their private space, plus shared space when every file sharing
    /// it is in the set.
    public let recoverable: Int64
    /// Folders that couldn't be read, so `recoverable` may be too low.
    public let unreadableFolders: Int
}

/// What the file system says about one file's space, to tell copies from clones.
public struct FileIdentity: Equatable, Sendable {
    public let fileID: UInt64
    public let cloneID: UInt64
    /// How many files share the clone. More than 1 means it really is a clone.
    public let cloneRefCount: UInt32
}

/// Refines the scan's figures for a chosen set of paths.
///
/// The scan's private size is a lower bound, because two clones of each other in the
/// same app each count as shared. Telling those apart needs the clone ID and the number
/// of files sharing it, which are read only here, since it costs more than a normal scan.
public enum RecoveryEstimator {
    private struct CloneGroup {
        var seen: UInt32 = 0
        let total: UInt32
        var sharedBytes: Int64
    }

    private struct HardLink {
        var seen: UInt32 = 0
        let total: UInt32
        let allocated: Int64
        let privateBytes: Int64
    }

    /// Blocks while it reads, so call it away from the main actor.
    public static func estimate(paths: [String]) -> RecoveryEstimate {
        // Listing a folder that lives only in the cloud must not download it.
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previous >= 0 {
                setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
            }
        }

        var allocated: Int64 = 0
        var privateBytes: Int64 = 0
        var unreadable = 0
        var clones: [UInt64: CloneGroup] = [:]
        var hardLinks: [UInt64: HardLink] = [:]

        func record(allocatedSize: Int64, privateSize: Int64, cloneID: UInt64, cloneCount: UInt32, links: UInt32, fileID: UInt64) {
            if links > 1 {
                // Space returns only once the last name is gone, and counts once.
                if hardLinks[fileID] == nil {
                    allocated += allocatedSize
                    hardLinks[fileID] = HardLink(total: links, allocated: allocatedSize, privateBytes: privateSize)
                }
                hardLinks[fileID]?.seen += 1
                return
            }
            allocated += allocatedSize
            privateBytes += privateSize
            if cloneCount > 1, allocatedSize > privateSize {
                var group = clones[cloneID] ?? CloneGroup(total: cloneCount, sharedBytes: 0)
                group.seen += 1
                // Clones can diverge, so the share is taken from the one sharing the most.
                group.sharedBytes = max(group.sharedBytes, allocatedSize - privateSize)
                clones[cloneID] = group
            }
        }

        var list = attrlist()
        list.bitmapcount = 5
        list.commonattr = BulkRequest.commonReturned | BulkRequest.commonError | BulkRequest.commonName
            | BulkRequest.commonObjectType | BulkRequest.commonFileID
        list.fileattr = BulkRequest.fileLinkCount | BulkRequest.fileAllocatedSize
        list.forkattr = BulkRequest.extendedPrivateSize | BulkRequest.extendedCloneID | BulkRequest.extendedCloneRefCount

        let size = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }

        var stack: [String] = []
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                stack.append(path)
            } else if let file = fileAttributes(atPath: path, list: list, buffer: buffer, size: size) {
                record(
                    allocatedSize: file.allocated,
                    privateSize: file.privateSize,
                    cloneID: file.cloneID,
                    cloneCount: file.cloneRefCount,
                    links: file.linkCount,
                    fileID: file.fileID
                )
            }
        }

        while let folder = stack.popLast() {
            let descriptor = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                unreadable += 1
                continue
            }
            defer { close(descriptor) }

            while true {
                let count = getattrlistbulk(descriptor, &list, buffer, size, BulkRequest.options)
                if count < 0 {
                    if errno == EINTR { continue }
                    unreadable += 1
                    break
                }
                if count == 0 { break }

                var cursor = UnsafeRawPointer(buffer)
                for _ in 0..<count {
                    let (entry, length) = BulkEntry.decode(at: cursor)
                    cursor += length
                    guard entry.error == 0 else { continue }

                    switch entry.kind {
                    case .directory:
                        // Dataless and mounted folders hold nothing of this set on this volume.
                        if entry.mountStatus & BulkRequest.directoryIsMountPoint == 0 {
                            stack.append(folder + "/" + String(decoding: entry.name, as: UTF8.self))
                        }
                    case .file:
                        record(
                            allocatedSize: entry.allocated,
                            privateSize: entry.privateSize,
                            cloneID: entry.cloneID,
                            cloneCount: entry.cloneRefCount,
                            links: entry.linkCount,
                            fileID: entry.fileID
                        )
                    case .symlink, .other:
                        allocated += entry.allocated
                        privateBytes += entry.allocated
                    }
                }
            }
        }

        var recoverable = privateBytes
        for group in clones.values where group.seen >= group.total {
            recoverable += group.sharedBytes
        }
        for link in hardLinks.values where link.seen >= link.total {
            recoverable += link.privateBytes
        }
        return RecoveryEstimate(allocated: allocated, recoverable: recoverable, unreadableFolders: unreadable)
    }

    /// Reads a single file's identity without following links.
    public static func identity(ofFileAt path: String) -> FileIdentity? {
        var list = attrlist()
        list.bitmapcount = 5
        list.commonattr = BulkRequest.commonReturned | BulkRequest.commonName
            | BulkRequest.commonObjectType | BulkRequest.commonFileID
        list.fileattr = BulkRequest.fileLinkCount | BulkRequest.fileAllocatedSize
        list.forkattr = BulkRequest.extendedPrivateSize | BulkRequest.extendedCloneID | BulkRequest.extendedCloneRefCount

        let size = 4096
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        guard let file = fileAttributes(atPath: path, list: list, buffer: buffer, size: size) else { return nil }
        return FileIdentity(fileID: file.fileID, cloneID: file.cloneID, cloneRefCount: file.cloneRefCount)
    }

    private static func fileAttributes(
        atPath path: String,
        list: attrlist,
        buffer: UnsafeMutableRawPointer,
        size: Int
    ) -> (allocated: Int64, privateSize: Int64, cloneID: UInt64, cloneRefCount: UInt32, linkCount: UInt32, fileID: UInt64)? {
        var request = list
        // `getattrlist` rejects the error attribute unless asked to report through it.
        request.commonattr &= ~BulkRequest.commonError
        guard getattrlist(path, &request, buffer, size, UInt32(BulkRequest.options | BulkRequest.noFollow)) == 0 else {
            return nil
        }
        let (entry, _) = BulkEntry.decode(at: UnsafeRawPointer(buffer))
        guard entry.kind == .file else {
            return (entry.allocated, entry.allocated, 0, 0, 1, entry.fileID)
        }
        return (entry.allocated, entry.privateSize, entry.cloneID, entry.cloneRefCount, entry.linkCount, entry.fileID)
    }
}
