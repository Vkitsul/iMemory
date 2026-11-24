// Read-only spike: compares two ways of measuring a folder tree
// and reads the volume counters. Changes nothing.
import Foundation
import Darwin

struct Totals { var files = 0, dirs = 0, errors = 0; var logical: Int64 = 0, allocated: Int64 = 0, priv: Int64 = 0, hardlinkDup: Int64 = 0 }

// MARK: FileManager + URLResourceValues
func scanFoundation(_ root: String) -> Totals {
    var t = Totals()
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey]
    guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return t }
    for case let u as URL in e {
        guard let v = try? u.resourceValues(forKeys: Set(keys)) else { t.errors += 1; continue }
        if v.isDirectory == true { t.dirs += 1 } else if v.isRegularFile == true {
            t.files += 1
            t.logical += Int64(v.fileSize ?? 0)
            t.allocated += Int64(v.totalFileAllocatedSize ?? 0)
        }
    }
    return t
}

// MARK: getattrlistbulk
let cmnReturned: UInt32 = 0x8000_0000, cmnName: UInt32 = 0x1, cmnObjType: UInt32 = 0x8, cmnFileID: UInt32 = 0x0200_0000
let fileLink: UInt32 = 0x1, fileTotal: UInt32 = 0x2, fileAlloc: UInt32 = 0x4
let extPrivate: UInt32 = 0x8 // ATTR_CMNEXT_PRIVATESIZE
let optPack: UInt64 = 0x8, optExt: UInt64 = 0x20

func scanBulk(_ root: String) -> Totals {
    var t = Totals()
    var seen = Set<UInt64>()
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 256 * 1024, alignment: 8)
    defer { buf.deallocate() }
    var stack = [root]
    while let dir = stack.popLast() {
        let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd < 0 { t.errors += 1; continue }
        defer { close(fd) }
        var al = attrlist()
        al.bitmapcount = 5
        al.commonattr = cmnReturned | cmnName | cmnObjType | cmnFileID
        al.fileattr = fileLink | fileTotal | fileAlloc
        al.forkattr = extPrivate
        while true {
            let n = getattrlistbulk(fd, &al, buf, 256 * 1024, optPack | optExt)
            if n < 0 { t.errors += 1; break }
            if n == 0 { break }
            var p = buf
            for _ in 0..<n {
                let len = p.loadUnaligned(as: UInt32.self)
                var q = p + 4 + 20 // lunghezza + attribute_set_t
                let nameRef = q
                let nameOff = q.loadUnaligned(as: Int32.self)
                q += 8
                let type = q.loadUnaligned(as: UInt32.self); q += 4
                let fid = q.loadUnaligned(as: UInt64.self); q += 8
                if type == 2 {
                    t.dirs += 1
                    let name = String(cString: (nameRef + Int(nameOff)).assumingMemoryBound(to: CChar.self))
                    stack.append(dir + "/" + name)
                } else if type == 1 {
                    let links = q.loadUnaligned(as: UInt32.self); q += 4
                    let total = q.loadUnaligned(as: Int64.self); q += 8
                    let alloc = q.loadUnaligned(as: Int64.self); q += 8
                    let priv = q.loadUnaligned(as: Int64.self)
                    t.files += 1
                    if links > 1, !seen.insert(fid).inserted { t.hardlinkDup += alloc } else {
                        t.logical += total; t.allocated += alloc; t.priv += priv
                    }
                }
                p += Int(len)
            }
        }
    }
    return t
}

func mb(_ b: Int64) -> String { String(format: "%10.1f MB", Double(b) / 1_048_576) }
func gb(_ b: Int64) -> String { String(format: "%7.2f GB", Double(b) / 1_000_000_000) }

let home = NSHomeDirectory()
let v = try URL(fileURLWithPath: "/System/Volumes/Data").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityForOpportunisticUsageKey])
print("VOLUME total      ", gb(Int64(v.volumeTotalCapacity ?? 0)))
print("VOLUME available  ", gb(Int64(v.volumeAvailableCapacity ?? 0)))
print("VOLUME important  ", gb(v.volumeAvailableCapacityForImportantUsage ?? 0))
print("VOLUME opportun.  ", gb(v.volumeAvailableCapacityForOpportunisticUsage ?? 0))

for root in ["/Applications", home + "/Library/Caches", home + "/Library/Developer"] {
    print("\n== \(root)")
    let c0 = ContinuousClock.now
    let a = scanFoundation(root)
    let c1 = ContinuousClock.now
    let b = scanBulk(root)
    let c2 = ContinuousClock.now
    print("Foundation \(c0.duration(to: c1))  files \(a.files) dirs \(a.dirs) err \(a.errors) logical\(mb(a.logical)) alloc\(mb(a.allocated))")
    print("Bulk       \(c1.duration(to: c2))  files \(b.files) dirs \(b.dirs) err \(b.errors) logical\(mb(b.logical)) alloc\(mb(b.allocated)) private\(mb(b.priv)) hardlinkDup\(mb(b.hardlinkDup))")
}
