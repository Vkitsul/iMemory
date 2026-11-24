import Foundation

public struct NodeID: Hashable, Sendable {
    public let index: UInt32

    @inlinable public init(index: UInt32) {
        self.index = index
    }
}

public enum NodeKind: UInt8, Sendable {
    case file, directory, symlink, other
}

public struct NodeFlags: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The directory could not be listed, so its total is a lower bound.
    public static let unreadable = NodeFlags(rawValue: 1 << 0)
    /// Another path owns this file's data, so its sizes here are zero.
    public static let hardLinkDuplicate = NodeFlags(rawValue: 1 << 1)
    /// Another volume is mounted here and was not entered.
    public static let mountPoint = NodeFlags(rawValue: 1 << 2)
    /// The content is in the cloud and was not downloaded.
    public static let dataless = NodeFlags(rawValue: 1 << 3)
    /// Skipped because of `ScanOptions.excludedNames`.
    public static let excluded = NodeFlags(rawValue: 1 << 4)
    /// The scanner saw more than one link and still has to pick an owner.
    static let multipleLinks = NodeFlags(rawValue: 1 << 7)
}

public struct NodeSizes: Equatable, Sendable {
    /// Length of the content.
    public var logical: Int64
    /// Space on disk, the same figure `du` reports.
    public var allocated: Int64
    /// Allocated space not shared with an APFS clone. Summing this gives a lower
    /// bound on what deleting a folder frees: clones of each other inside the same
    /// folder each count as shared, yet deleting both frees their space.
    public var privateBytes: Int64

    public init(logical: Int64, allocated: Int64, privateBytes: Int64) {
        self.logical = logical
        self.allocated = allocated
        self.privateBytes = privateBytes
    }
}

/// Compact, immutable result of a scan, stored as parallel arrays to keep the
/// per-node overhead small on trees with millions of entries.
public struct FileTree: Sendable {
    static let noParent = UInt32.max

    var parents: [UInt32]
    var kinds: [UInt8]
    var flagBits: [UInt8]
    var nameOffsets: [UInt32]
    var nameLengths: [UInt16]
    var nameBytes: [UInt8]
    var logicalSizes: [Int64]
    var allocatedSizes: [Int64]
    var privateSizes: [Int64]
    var fileIDs: [UInt64]
    var modTimes: [Int64]
    var childStarts: [UInt32]
    var childIndices: [UInt32]
    var descendantCounts: [UInt32]
    let rootIndex: UInt32

    public var root: NodeID { NodeID(index: rootIndex) }
    public var count: Int { parents.count }

    public func kind(of node: NodeID) -> NodeKind {
        NodeKind(rawValue: kinds[Int(node.index)]) ?? .other
    }

    public func flags(of node: NodeID) -> NodeFlags {
        NodeFlags(rawValue: flagBits[Int(node.index)])
    }

    /// For a directory, the total of everything inside it.
    public func sizes(of node: NodeID) -> NodeSizes {
        let index = Int(node.index)
        return NodeSizes(
            logical: logicalSizes[index],
            allocated: allocatedSizes[index],
            privateBytes: privateSizes[index]
        )
    }

    public func fileID(of node: NodeID) -> UInt64 { fileIDs[Int(node.index)] }

    public func modificationDate(of node: NodeID) -> Date {
        Date(timeIntervalSince1970: TimeInterval(modTimes[Int(node.index)]))
    }

    public func descendantCount(of node: NodeID) -> Int {
        Int(descendantCounts[Int(node.index)])
    }

    public func parent(of node: NodeID) -> NodeID? {
        let parent = parents[Int(node.index)]
        return parent == Self.noParent ? nil : NodeID(index: parent)
    }

    /// Children, largest first. Ties are ordered by name so the result is stable.
    public func children(of node: NodeID) -> [NodeID] {
        let index = Int(node.index)
        let range = Int(childStarts[index])..<Int(childStarts[index + 1])
        return childIndices[range].map { NodeID(index: $0) }
    }

    public func name(of node: NodeID) -> String {
        String(decoding: nameSlice(Int(node.index)), as: UTF8.self)
    }

    public func path(of node: NodeID) -> String {
        String(decoding: pathBytes(of: node), as: UTF8.self)
    }

    /// The exact bytes of the path, which may not be valid UTF-8 on every volume.
    public func pathBytes(of node: NodeID) -> [UInt8] {
        var chain: [Int] = []
        var current = node.index
        while current != Self.noParent {
            chain.append(Int(current))
            current = parents[Int(current)]
        }
        var bytes: [UInt8] = []
        for index in chain.reversed() {
            if let last = bytes.last, last != UInt8(ascii: "/") {
                bytes.append(UInt8(ascii: "/"))
            }
            bytes.append(contentsOf: nameSlice(index))
        }
        return bytes
    }

    /// Bytes held by the tree's arrays, excluding allocator overhead.
    public var storageBytes: Int {
        let perNode = 4 + 1 + 1 + 4 + 2 + 8 + 8 + 8 + 8 + 8 + 4 + 4 + 4
        return count * perNode + nameBytes.count
    }

    func nameSlice(_ index: Int) -> ArraySlice<UInt8> {
        let start = Int(nameOffsets[index])
        return nameBytes[start..<(start + Int(nameLengths[index]))]
    }
}
