extension FileTree {
    public func childCount(of node: NodeID) -> Int {
        let index = Int(node.index)
        return Int(childStarts[index + 1] - childStarts[index])
    }

    public func child(of parent: NodeID, named name: String) -> NodeID? {
        let index = Int(parent.index)
        let target = Array(name.utf8)
        for raw in childIndices[Int(childStarts[index])..<Int(childStarts[index + 1])]
        where nameSlice(Int(raw)).elementsEqual(target) {
            return NodeID(index: raw)
        }
        return nil
    }

    /// Finds a node from a path relative to the root, such as `Users/name/Library`.
    public func node(atRelativePath path: String) -> NodeID? {
        var current = root
        for component in path.split(separator: "/") {
            guard let next = child(of: current, named: String(component)) else { return nil }
            current = next
        }
        return current
    }

    /// The largest folders worth showing, biggest first.
    ///
    /// A folder that is almost entirely one subfolder says nothing that its subfolder
    /// doesn't, so it is skipped: `/Users` never appears just because it holds `/Users/name`.
    public func largestDirectories(limit: Int) -> [NodeID] {
        var frontier = [root]
        var result: [NodeID] = []

        while result.count < limit, let position = frontier.indices.max(by: {
            allocatedSizes[Int(frontier[$0].index)] < allocatedSizes[Int(frontier[$1].index)]
        }) {
            let node = frontier.remove(at: position)
            let size = allocatedSizes[Int(node.index)]
            guard size > 0 else { break }

            let subfolders = largestSubfolders(of: node, limit: 8)
            if let first = subfolders.first, Double(allocatedSizes[Int(first.index)]) >= Double(size) * 0.9 {
                frontier.append(first)
                continue
            }
            if node != root {
                result.append(node)
            }
            frontier.append(contentsOf: subfolders)
        }
        return result
    }

    /// Directories under `node`, at any depth, that could not be listed.
    public func unreadableDirectoryCount(under node: NodeID) -> Int {
        var count = 0
        let marker = NodeFlags.unreadable.rawValue
        for index in 0..<self.count where flagBits[index] & marker != 0 {
            var current = UInt32(index)
            while current != Self.noParent {
                if current == node.index {
                    count += 1
                    break
                }
                current = parents[Int(current)]
            }
        }
        return count
    }

    private func largestSubfolders(of node: NodeID, limit: Int) -> [NodeID] {
        let index = Int(node.index)
        var result: [NodeID] = []
        // Children are sorted by size, so the first folders met are the largest.
        for raw in childIndices[Int(childStarts[index])..<Int(childStarts[index + 1])] {
            guard allocatedSizes[Int(raw)] > 0 else { break }
            if kinds[Int(raw)] == NodeKind.directory.rawValue {
                result.append(NodeID(index: raw))
                if result.count == limit { break }
            }
        }
        return result
    }
}
