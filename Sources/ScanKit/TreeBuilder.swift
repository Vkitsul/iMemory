import Darwin

/// Turns the workers' buffers into a `FileTree` once scanning has finished.
enum TreeBuilder {
    static func build(buffers: inout [NodeBuffer], rootRef: NodeRef) -> (FileTree, ScanStatistics) {
        var statistics = ScanStatistics()

        var bases: [UInt32] = []
        var nodeCount = 0
        var nameCount = 0
        for buffer in buffers {
            bases.append(UInt32(nodeCount))
            nodeCount += buffer.count
            nameCount += buffer.nameBytes.count
        }

        var parents = [UInt32](); parents.reserveCapacity(nodeCount)
        var kinds = [UInt8](); kinds.reserveCapacity(nodeCount)
        var flagBits = [UInt8](); flagBits.reserveCapacity(nodeCount)
        var nameOffsets = [UInt32](); nameOffsets.reserveCapacity(nodeCount)
        var nameLengths = [UInt16](); nameLengths.reserveCapacity(nodeCount)
        var nameBytes = [UInt8](); nameBytes.reserveCapacity(nameCount)
        var logical = [Int64](); logical.reserveCapacity(nodeCount)
        var allocated = [Int64](); allocated.reserveCapacity(nodeCount)
        var privateBytes = [Int64](); privateBytes.reserveCapacity(nodeCount)
        var fileIDs = [UInt64](); fileIDs.reserveCapacity(nodeCount)
        var modTimes = [Int64](); modTimes.reserveCapacity(nodeCount)

        func resolve(_ raw: UInt64) -> UInt32 {
            let ref = NodeRef(rawValue: raw)
            return bases[ref.buffer] + UInt32(ref.position)
        }

        var lateFlags: [(ref: UInt64, flags: UInt8)] = []
        for position in buffers.indices {
            // Taking the buffer out frees it after this pass, which keeps the peak low.
            var buffer = NodeBuffer()
            swap(&buffer, &buffers[position])

            let nameBase = UInt32(nameBytes.count)
            for ref in buffer.parentRefs {
                parents.append(ref == ScanStatistics.noParentRef ? FileTree.noParent : resolve(ref))
            }
            kinds.append(contentsOf: buffer.kinds)
            flagBits.append(contentsOf: buffer.flagBits)
            nameOffsets.append(contentsOf: buffer.nameOffsets.lazy.map { $0 + nameBase })
            nameLengths.append(contentsOf: buffer.nameLengths)
            nameBytes.append(contentsOf: buffer.nameBytes)
            logical.append(contentsOf: buffer.logicalSizes)
            allocated.append(contentsOf: buffer.allocatedSizes)
            privateBytes.append(contentsOf: buffer.privateSizes)
            fileIDs.append(contentsOf: buffer.fileIDs)
            modTimes.append(contentsOf: buffer.modTimes)

            lateFlags.append(contentsOf: buffer.lateFlags)
            statistics.errorCounts.merge(buffer.errorCounts, uniquingKeysWith: +)
            for sample in buffer.errorSamples where statistics.errorSamples.count < ScanStatistics.maximumSamples {
                statistics.errorSamples.append(sample)
            }
        }

        for (ref, flags) in lateFlags {
            flagBits[Int(resolve(ref))] |= flags
        }

        // Consuming the locals leaves the tree as sole owner, so that mutating it below
        // doesn't copy the arrays.
        var tree = FileTree(
            parents: consume parents,
            kinds: consume kinds,
            flagBits: consume flagBits,
            nameOffsets: consume nameOffsets,
            nameLengths: consume nameLengths,
            nameBytes: consume nameBytes,
            logicalSizes: consume logical,
            allocatedSizes: consume allocated,
            privateSizes: consume privateBytes,
            fileIDs: consume fileIDs,
            modTimes: consume modTimes,
            childStarts: [],
            childIndices: [],
            descendantCounts: [],
            rootIndex: resolve(rootRef.rawValue)
        )

        settleHardLinks(in: &tree, statistics: &statistics)
        linkChildren(in: &tree)
        accumulateTotals(in: &tree)
        sortChildren(in: &tree)
        collectCounts(from: tree, into: &statistics)

        return (tree, statistics)
    }

    /// Counts each hard-linked file once, like `du`. The owner is the smallest path,
    /// not the first one seen, so that repeated scans attribute space identically
    /// whichever worker reached each link first. Otherwise comparing two scans would
    /// show growth that never happened.
    private static func settleHardLinks(in tree: inout FileTree, statistics: inout ScanStatistics) {
        var linksByFile: [UInt64: [UInt32]] = [:]
        let marker = NodeFlags.multipleLinks.rawValue
        for index in 0..<tree.count where tree.flagBits[index] & marker != 0 {
            tree.flagBits[index] &= ~marker
            linksByFile[tree.fileIDs[index], default: []].append(UInt32(index))
        }

        for links in linksByFile.values where links.count > 1 {
            let owner = links.min { a, b in
                tree.pathBytes(of: NodeID(index: a)).lexicographicallyPrecedes(tree.pathBytes(of: NodeID(index: b)))
            }
            for link in links where link != owner {
                let index = Int(link)
                statistics.hardLinkDuplicates += 1
                statistics.hardLinkDuplicateBytes += tree.allocatedSizes[index]
                tree.logicalSizes[index] = 0
                tree.allocatedSizes[index] = 0
                tree.privateSizes[index] = 0
                tree.flagBits[index] |= NodeFlags.hardLinkDuplicate.rawValue
            }
        }
    }

    private static func linkChildren(in tree: inout FileTree) {
        var starts = [UInt32](repeating: 0, count: tree.count + 1)
        for parent in tree.parents where parent != FileTree.noParent {
            starts[Int(parent) + 1] += 1
        }
        for index in 0..<tree.count {
            starts[index + 1] += starts[index]
        }

        var nextSlot = starts
        var indices = [UInt32](repeating: 0, count: starts[tree.count] == 0 ? 0 : Int(starts[tree.count]))
        for (index, parent) in tree.parents.enumerated() where parent != FileTree.noParent {
            indices[Int(nextSlot[Int(parent)])] = UInt32(index)
            nextSlot[Int(parent)] += 1
        }

        tree.childStarts = starts
        tree.childIndices = indices
    }

    private static func accumulateTotals(in tree: inout FileTree) {
        // Breadth-first order puts every parent before its children, so walking it
        // backwards adds each subtree to its parent after the subtree is complete.
        var order = [UInt32](); order.reserveCapacity(tree.count)
        order.append(tree.rootIndex)
        var cursor = 0
        while cursor < order.count {
            let index = Int(order[cursor])
            cursor += 1
            order.append(contentsOf: tree.childIndices[Int(tree.childStarts[index])..<Int(tree.childStarts[index + 1])])
        }

        var descendants = [UInt32](repeating: 0, count: tree.count)
        for raw in order.reversed() {
            let index = Int(raw)
            let parent = tree.parents[index]
            guard parent != FileTree.noParent else { continue }
            let target = Int(parent)
            tree.logicalSizes[target] += tree.logicalSizes[index]
            tree.allocatedSizes[target] += tree.allocatedSizes[index]
            tree.privateSizes[target] += tree.privateSizes[index]
            descendants[target] += descendants[index] + 1
        }
        tree.descendantCounts = descendants
    }

    private static func sortChildren(in tree: inout FileTree) {
        let sizes = tree.allocatedSizes
        let offsets = tree.nameOffsets
        let lengths = tree.nameLengths
        let names = tree.nameBytes
        let starts = tree.childStarts

        names.withUnsafeBytes { nameBuffer in
            tree.childIndices.withUnsafeMutableBufferPointer { children in
                for index in 0..<(starts.count - 1) {
                    let range = Int(starts[index])..<Int(starts[index + 1])
                    guard range.count > 1 else { continue }
                    children[range].sort { a, b in
                        let sizeA = sizes[Int(a)], sizeB = sizes[Int(b)]
                        if sizeA != sizeB { return sizeA > sizeB }
                        let lengthA = Int(lengths[Int(a)]), lengthB = Int(lengths[Int(b)])
                        let order = memcmp(
                            nameBuffer.baseAddress! + Int(offsets[Int(a)]),
                            nameBuffer.baseAddress! + Int(offsets[Int(b)]),
                            min(lengthA, lengthB)
                        )
                        return order != 0 ? order < 0 : lengthA < lengthB
                    }
                }
            }
        }
    }

    private static func collectCounts(from tree: FileTree, into statistics: inout ScanStatistics) {
        for index in 0..<tree.count {
            let flags = NodeFlags(rawValue: tree.flagBits[index])
            switch NodeKind(rawValue: tree.kinds[index]) {
            case .file:
                statistics.files += 1
                if flags.contains(.dataless) { statistics.datalessFiles += 1 }
            case .directory:
                statistics.directories += 1
                if flags.contains(.unreadable) { statistics.unreadableDirectories += 1 }
                if flags.contains(.mountPoint) { statistics.mountPoints += 1 }
                if flags.contains(.dataless) { statistics.datalessDirectories += 1 }
            case .symlink:
                statistics.symlinks += 1
            case .other, .none:
                statistics.otherItems += 1
            }
            if flags.contains(.excluded) { statistics.excludedItems += 1 }
        }
    }
}
