import ScanKit
import SwiftUI

struct TreemapView: View {
    let explorer: Explorer

    @State private var cells: [TreemapCell] = []
    @State private var labels: [String?] = []
    @State private var hovered: TreemapCell?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                TreemapCanvas(
                    cells: cells,
                    labels: labels,
                    selection: explorer.selection,
                    layoutKey: LayoutKey(root: explorer.current, size: geometry.size)
                )
                .equatable()
                .contentShape(.rect)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = cell(at: point)
                    case .ended: hovered = nil
                    }
                }
                .simultaneousGesture(SpatialTapGesture().onEnded { value in
                    explorer.selection = cell(at: value.location)?.node
                })
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                    if let node = directory(at: value.location) {
                        explorer.show(node)
                    }
                })
                .task(id: LayoutKey(root: explorer.current, size: geometry.size)) {
                    relayout(size: geometry.size)
                }
            }
            Divider()
            statusLine
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder map. Use the list beside it to navigate with the keyboard.")
    }

    private var statusLine: some View {
        HStack {
            Text(statusText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var statusText: String {
        guard let hovered else { return "Click to select, double-click to open a folder." }
        guard let node = hovered.node else {
            return "\(Format.count(hovered.groupedItems)) items too small to draw"
        }
        let tree = explorer.tree
        return "\(tree.name(of: node)): \(Format.bytes(tree.sizes(of: node).allocated))"
    }

    private func relayout(size: CGSize) {
        let tree = explorer.tree
        // The cell under the mouse belonged to the previous layout.
        hovered = nil
        cells = Treemap.cells(tree: tree, root: explorer.current, size: size)
        labels = cells.map { cell in
            guard let node = cell.node else {
                return cell.groupedItems > 0 && cell.rect.width >= 70 && cell.rect.height >= 15
                    ? "\(Format.count(cell.groupedItems)) small"
                    : nil
            }
            // Resolving names only for cells wide enough to show one saves most of the work.
            return cell.rect.width >= 44 && cell.rect.height >= 15 ? tree.name(of: node) : nil
        }
    }

    /// The deepest cell under the point. Children follow their parents in `cells`.
    private func cell(at point: CGPoint) -> TreemapCell? {
        cells.last { $0.rect.contains(point) }
    }

    /// The folder a double click should open: the nested one if there is one, otherwise
    /// the top-level folder containing the point.
    private func directory(at point: CGPoint) -> NodeID? {
        cells.last { $0.rect.contains(point) && $0.isDirectory }?.node
    }
}

private struct LayoutKey: Hashable {
    let root: NodeID
    let size: CGSize

    func hash(into hasher: inout Hasher) {
        hasher.combine(root)
        hasher.combine(size.width)
        hasher.combine(size.height)
    }
}

/// Drawing is separate from hover state, so that moving the mouse doesn't redraw the map.
private struct TreemapCanvas: View, Equatable {
    let cells: [TreemapCell]
    let labels: [String?]
    let selection: NodeID?
    let layoutKey: LayoutKey

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selection == rhs.selection && lhs.layoutKey == rhs.layoutKey && lhs.cells.count == rhs.cells.count
            && lhs.cells.first?.rect == rhs.cells.first?.rect && lhs.cells.first?.node == rhs.cells.first?.node
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, _ in
            for (index, cell) in cells.enumerated() {
                let rect = cell.rect.insetBy(dx: 0.5, dy: 0.5)
                guard rect.width > 0, rect.height > 0 else { continue }
                context.fill(Path(rect), with: .color(TreemapPalette.fill(for: cell)))

                if let label = labels[index] {
                    let labelRect = cell.hasNestedCells
                        ? CGRect(x: rect.minX + 4, y: rect.minY + 1, width: rect.width - 8, height: Treemap.headerHeight - 2)
                        : rect.insetBy(dx: 3, dy: 1)
                    let text = Text(label)
                        .font(.system(size: 10.5, weight: cell.depth == 0 ? .medium : .regular))
                        .foregroundStyle(TreemapPalette.text(for: cell))
                    // Clipped on one line: wrapping would break names in the middle of a word.
                    var clipped = context
                    clipped.clip(to: Path(labelRect))
                    clipped.draw(context.resolve(text), at: labelRect.origin, anchor: .topLeading)
                }
            }

            if let selected = cells.last(where: { $0.node != nil && $0.node == selection }) {
                context.stroke(Path(selected.rect.insetBy(dx: 1, dy: 1)), with: .color(.accentColor), lineWidth: 2.5)
            }
        }
    }
}

private enum TreemapPalette {
    private static let hues: [Double] = [0.60, 0.47, 0.76, 0.08, 0.92, 0.34, 0.54, 0.14]

    static func fill(for cell: TreemapCell) -> Color {
        guard cell.node != nil else { return Color(white: 0.62) }
        let hue = hues[cell.group % hues.count]
        if cell.depth == 0 {
            if !cell.isDirectory { return Color(hue: hue, saturation: 0.25, brightness: 0.74) }
            return Color(hue: hue, saturation: 0.55, brightness: 0.48)
        }
        return cell.isDirectory
            ? Color(hue: hue, saturation: 0.35, brightness: 0.86)
            : Color(hue: hue, saturation: 0.18, brightness: 0.92)
    }

    static func text(for cell: TreemapCell) -> Color {
        cell.depth == 0 && cell.isDirectory ? .white : Color(white: 0.1)
    }
}
