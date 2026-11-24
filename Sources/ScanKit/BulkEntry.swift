import Darwin

/// Attributes requested from `getattrlistbulk`, with values from `<sys/attr.h>`.
enum BulkRequest {
    static let commonReturned: UInt32 = 0x8000_0000
    static let commonError: UInt32 = 0x2000_0000
    static let commonName: UInt32 = 0x0000_0001
    static let commonObjectType: UInt32 = 0x0000_0008
    static let commonModTime: UInt32 = 0x0000_0400
    static let commonFlags: UInt32 = 0x0004_0000
    static let commonFileID: UInt32 = 0x0200_0000

    static let directoryMountStatus: UInt32 = 0x0000_0004
    static let directoryAllocatedSize: UInt32 = 0x0000_0008
    static let directoryDataLength: UInt32 = 0x0000_0020

    static let fileLinkCount: UInt32 = 0x0000_0001
    static let fileTotalSize: UInt32 = 0x0000_0002
    static let fileAllocatedSize: UInt32 = 0x0000_0004

    /// `ATTR_CMNEXT_PRIVATESIZE`: allocated bytes not shared with an APFS clone.
    static let extendedPrivateSize: UInt32 = 0x0000_0008
    /// `ATTR_CMNEXT_CLONEID`: the same for every file sharing the same clone.
    static let extendedCloneID: UInt32 = 0x0000_0100
    /// `ATTR_CMNEXT_CLONE_REFCNT`: how many files share it.
    static let extendedCloneRefCount: UInt32 = 0x0000_1000

    /// `FSOPT_ATTR_CMN_EXTENDED`: makes `forkattr` carry `ATTR_CMNEXT_*` bits.
    static let options: UInt64 = 0x0000_0020
    /// `FSOPT_NOFOLLOW`, for `getattrlist` on a single path.
    static let noFollow: UInt64 = 0x0000_0001

    static let directoryIsMountPoint: UInt32 = 0x0000_0001
    static let fileIsDataless: UInt32 = 0x4000_0000

    static var attributeList: attrlist {
        var list = attrlist()
        list.bitmapcount = 5
        list.commonattr = commonReturned | commonError | commonName | commonObjectType
            | commonModTime | commonFlags | commonFileID
        list.dirattr = directoryMountStatus | directoryAllocatedSize | directoryDataLength
        list.fileattr = fileLinkCount | fileTotalSize | fileAllocatedSize
        list.forkattr = extendedPrivateSize
        return list
    }
}

/// One entry decoded from a `getattrlistbulk` buffer.
///
/// `name` points into the buffer, so it is valid only until the next call.
struct BulkEntry {
    var error: UInt32 = 0
    var name = UnsafeBufferPointer<UInt8>(start: nil, count: 0)
    var objectType: UInt32 = 0
    var modTime: Int64 = 0
    var flags: UInt32 = 0
    var fileID: UInt64 = 0
    var mountStatus: UInt32 = 0
    var linkCount: UInt32 = 1
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var privateSize: Int64 = 0
    var cloneID: UInt64 = 0
    var cloneRefCount: UInt32 = 0

    var kind: NodeKind {
        switch objectType {
        case 1: .file
        case 2: .directory
        case 5: .symlink
        default: .other
        }
    }

    /// Decodes the entry at `start` and returns it with its total length.
    ///
    /// The kernel omits the fields it did not return, so each field is read only
    /// when its bit is set. Order matters: `ATTR_CMN_ERROR` comes straight after
    /// the returned set, then common, directory, file, and fork attributes.
    @inline(__always)
    static func decode(at start: UnsafeRawPointer) -> (entry: BulkEntry, length: Int) {
        let length = Int(start.loadUnaligned(as: UInt32.self))
        var cursor = start + 4

        let commonSet = cursor.loadUnaligned(as: UInt32.self)
        let directorySet = (cursor + 8).loadUnaligned(as: UInt32.self)
        let fileSet = (cursor + 12).loadUnaligned(as: UInt32.self)
        let forkSet = (cursor + 16).loadUnaligned(as: UInt32.self)
        cursor += 20

        var entry = BulkEntry()

        if commonSet & BulkRequest.commonError != 0 {
            entry.error = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }
        if commonSet & BulkRequest.commonName != 0 {
            let offset = cursor.loadUnaligned(as: Int32.self)
            let byteCount = (cursor + 4).loadUnaligned(as: UInt32.self)
            let bytes = (cursor + Int(offset)).assumingMemoryBound(to: UInt8.self)
            // The stored length includes the trailing NUL.
            entry.name = UnsafeBufferPointer(start: bytes, count: max(0, Int(byteCount) - 1))
            cursor += 8
        }
        if commonSet & BulkRequest.commonObjectType != 0 {
            entry.objectType = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }
        if commonSet & BulkRequest.commonModTime != 0 {
            entry.modTime = cursor.loadUnaligned(as: Int64.self)
            cursor += 16
        }
        if commonSet & BulkRequest.commonFlags != 0 {
            entry.flags = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }
        if commonSet & BulkRequest.commonFileID != 0 {
            entry.fileID = cursor.loadUnaligned(as: UInt64.self)
            cursor += 8
        }

        if directorySet & BulkRequest.directoryMountStatus != 0 {
            entry.mountStatus = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }
        if directorySet & BulkRequest.directoryAllocatedSize != 0 {
            entry.allocated = cursor.loadUnaligned(as: Int64.self)
            cursor += 8
        }
        if directorySet & BulkRequest.directoryDataLength != 0 {
            entry.logical = cursor.loadUnaligned(as: Int64.self)
            cursor += 8
        }

        if fileSet & BulkRequest.fileLinkCount != 0 {
            entry.linkCount = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }
        if fileSet & BulkRequest.fileTotalSize != 0 {
            entry.logical = cursor.loadUnaligned(as: Int64.self)
            cursor += 8
        }
        if fileSet & BulkRequest.fileAllocatedSize != 0 {
            entry.allocated = cursor.loadUnaligned(as: Int64.self)
            cursor += 8
        }

        if forkSet & BulkRequest.extendedPrivateSize != 0 {
            entry.privateSize = cursor.loadUnaligned(as: Int64.self)
            cursor += 8
        }
        if forkSet & BulkRequest.extendedCloneID != 0 {
            entry.cloneID = cursor.loadUnaligned(as: UInt64.self)
            cursor += 8
        }
        if forkSet & BulkRequest.extendedCloneRefCount != 0 {
            entry.cloneRefCount = cursor.loadUnaligned(as: UInt32.self)
        }

        return (entry, length)
    }
}
