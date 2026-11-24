import CoreGraphics

public struct TreemapCell: Equatable, Sendable {
    /// `nil` for the cell that groups items too small to draw.
    public let node: NodeID?
    public let rect: CGRect
    /// 0 for the folder's own items, 1 for the items nested inside them.
    public let depth: Int
    /// Position of the top-level item, so that nested cells can share its colour.
    public let group: Int
    public let isDirectory: Bool
    /// How many items the cell stands for when `node` is `nil`.
    public let groupedItems: Int
    /// The space nested cells occupy, if this cell has any. The rest is its header.
    public let hasNestedCells: Bool
}

public enum Treemap {
    private static let minimumArea: [CGFloat] = [36, 64]
    private static let maximumCells: [Int] = [300, 60]

    /// Lays out a folder two levels deep. Parents come before their children, so
    /// drawing in order and hit-testing in reverse both work.
    ///
    /// Only the items that can be seen are visited, so cost depends on the size of
    /// the view and not on how many files the folder holds.
    public static func cells(tree: FileTree, root: NodeID, size: CGSize) -> [TreemapCell] {
        guard size.width > 0, size.height > 0, tree.sizes(of: root).allocated > 0 else { return [] }
        var cells: [TreemapCell] = []
        addLevel(tree: tree, parent: root, rect: CGRect(origin: .zero, size: size), depth: 0, group: 0, into: &cells)
        return cells
    }

    private static func addLevel(
        tree: FileTree,
        parent: NodeID,
        rect: CGRect,
        depth: Int,
        group: Int,
        into cells: inout [TreemapCell]
    ) {
        let total = tree.sizes(of: parent).allocated
        guard total > 0 else { return }

        let index = Int(parent.index)
        let children = tree.childIndices[Int(tree.childStarts[index])..<Int(tree.childStarts[index + 1])]
        let areaPerByte = (rect.width * rect.height) / CGFloat(total)

        var nodes: [NodeID] = []
        var values: [Double] = []
        var includedBytes: Int64 = 0
        for raw in children {
            let bytes = tree.allocatedSizes[Int(raw)]
            guard bytes > 0, CGFloat(bytes) * areaPerByte >= minimumArea[depth], nodes.count < maximumCells[depth] else {
                break
            }
            nodes.append(NodeID(index: raw))
            values.append(Double(bytes))
            includedBytes += bytes
        }

        let remainder = total - includedBytes
        if remainder > 0 {
            values.append(Double(remainder))
        }
        let rects = squarify(values, in: rect)

        for (position, cellRect) in rects.enumerated() {
            guard position < nodes.count else {
                cells.append(TreemapCell(
                    node: nil,
                    rect: cellRect,
                    depth: depth,
                    group: group,
                    isDirectory: false,
                    groupedItems: children.count - nodes.count,
                    hasNestedCells: false
                ))
                continue
            }

            let node = nodes[position]
            let isDirectory = tree.kind(of: node) == .directory
            let cellGroup = depth == 0 ? position : group
            let nests = depth == 0 && isDirectory && cellRect.width >= 72 && cellRect.height >= 44
                && tree.childCount(of: node) > 0

            cells.append(TreemapCell(
                node: node,
                rect: cellRect,
                depth: depth,
                group: cellGroup,
                isDirectory: isDirectory,
                groupedItems: 0,
                hasNestedCells: nests
            ))

            if nests {
                let contents = innermostFolder(tree: tree, startingAt: node)
                let inner = CGRect(
                    x: cellRect.minX + 2,
                    y: cellRect.minY + headerHeight,
                    width: cellRect.width - 4,
                    height: cellRect.height - headerHeight - 2
                )
                addLevel(tree: tree, parent: contents, rect: inner, depth: 1, group: cellGroup, into: &cells)
            }
        }
    }

    /// A folder that is almost entirely one subfolder would draw as a single block, so
    /// the map shows what is inside that subfolder instead.
    private static func innermostFolder(tree: FileTree, startingAt start: NodeID) -> NodeID {
        var current = start
        while tree.childCount(of: current) > 0 {
            let index = Int(current.index)
            let largest = NodeID(index: tree.childIndices[Int(tree.childStarts[index])])
            guard tree.kind(of: largest) == .directory,
                  Double(tree.sizes(of: largest).allocated) >= Double(tree.sizes(of: current).allocated) * 0.9,
                  tree.childCount(of: largest) > 0
            else { break }
            current = largest
        }
        return current
    }

    public static let headerHeight: CGFloat = 18

    /// Squarified treemap (Bruls, Huizing, van Wijk). `values` must be sorted from
    /// largest to smallest. Returns one rectangle per value, in the same order.
    public static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else {
            return values.map { _ in CGRect(x: rect.minX, y: rect.minY, width: 0, height: 0) }
        }

        let scale = Double(rect.width * rect.height) / total
        var result: [CGRect] = []
        result.reserveCapacity(values.count)
        var remaining = rect
        var start = 0

        func worstRatio(sum: Double, largest: Double, smallest: Double, side: Double) -> Double {
            guard sum > 0, smallest > 0 else { return .infinity }
            let sideSquared = side * side
            let sumSquared = sum * sum
            return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
        }

        while start < values.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            var sum = values[start] * scale
            let largest = sum
            var ratio = worstRatio(sum: sum, largest: largest, smallest: sum, side: side)

            while end < values.count {
                let next = values[end] * scale
                let candidate = worstRatio(sum: sum + next, largest: largest, smallest: next, side: side)
                guard candidate <= ratio else { break }
                sum += next
                ratio = candidate
                end += 1
            }

            let thickness = side > 0 ? CGFloat(sum / side) : 0
            var offset: CGFloat = 0
            let isVerticalStrip = remaining.width >= remaining.height

            for position in start..<end {
                let length = sum > 0 ? CGFloat(values[position] * scale / sum) * CGFloat(side) : 0
                if isVerticalStrip {
                    result.append(CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length))
                } else {
                    result.append(CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness))
                }
                offset += length
            }

            if isVerticalStrip {
                remaining = CGRect(
                    x: remaining.minX + thickness,
                    y: remaining.minY,
                    width: max(0, remaining.width - thickness),
                    height: remaining.height
                )
            } else {
                remaining = CGRect(
                    x: remaining.minX,
                    y: remaining.minY + thickness,
                    width: remaining.width,
                    height: max(0, remaining.height - thickness)
                )
            }
            start = end
        }
        return result
    }
}
