/// Identifies a node while a scan runs: the buffer that holds it, then its position.
struct NodeRef {
    let rawValue: UInt64

    init(buffer: Int, position: Int) {
        rawValue = UInt64(buffer) << 32 | UInt64(position)
    }

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    var buffer: Int { Int(rawValue >> 32) }
    var position: Int { Int(rawValue & 0xFFFF_FFFF) }
}

/// Nodes found by one worker. Each worker owns its buffer, so appending needs no lock.
struct NodeBuffer: Sendable {
    var parentRefs: [UInt64] = []
    var kinds: [UInt8] = []
    var flagBits: [UInt8] = []
    var nameOffsets: [UInt32] = []
    var nameLengths: [UInt16] = []
    var nameBytes: [UInt8] = []
    var logicalSizes: [Int64] = []
    var allocatedSizes: [Int64] = []
    var privateSizes: [Int64] = []
    var fileIDs: [UInt64] = []
    var modTimes: [Int64] = []

    /// Flags learned about a directory after it was recorded, possibly by another worker.
    var lateFlags: [(ref: UInt64, flags: UInt8)] = []
    var errorCounts: [Int32: Int] = [:]
    var errorSamples: [ScanIssue] = []

    var count: Int { parentRefs.count }

    mutating func append(
        parent: UInt64,
        kind: NodeKind,
        flags: NodeFlags,
        name: UnsafeBufferPointer<UInt8>,
        sizes: NodeSizes,
        fileID: UInt64,
        modTime: Int64
    ) -> Int {
        let position = parentRefs.count
        parentRefs.append(parent)
        kinds.append(kind.rawValue)
        flagBits.append(flags.rawValue)
        nameOffsets.append(UInt32(nameBytes.count))
        nameLengths.append(UInt16(name.count))
        nameBytes.append(contentsOf: name)
        logicalSizes.append(sizes.logical)
        allocatedSizes.append(sizes.allocated)
        privateSizes.append(sizes.privateBytes)
        fileIDs.append(fileID)
        modTimes.append(modTime)
        return position
    }

    mutating func recordError(_ code: Int32, path: [UInt8]) {
        errorCounts[code, default: 0] += 1
        if errorSamples.count < ScanStatistics.maximumSamples {
            errorSamples.append(ScanIssue(path: String(decoding: path, as: UTF8.self), code: code))
        }
    }
}
