import AppKit
import ScanKit
import SwiftUI

/// The list of items in a folder.
///
/// This is an `NSTableView` because SwiftUI's `Table` diffs every row on each change:
/// reordering a folder with 42 000 items blocked the app for over 10 seconds. Reloading
/// an `NSTableView` only touches the rows on screen.
struct NodeTableView: NSViewRepresentable {
    let explorer: Explorer
    let rows: [NodeRow]
    let rowsVersion: Int
    let folder: NodeID
    let selected: NodeID?

    func makeCoordinator() -> Coordinator {
        Coordinator(explorer: explorer)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minimumWidth
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column.startsAscending)
            if !column.isTextual {
                tableColumn.headerCell.alignment = .right
            }
            table.addTableColumn(tableColumn)
        }
        table.sortDescriptors = [NSSortDescriptor(key: Column.size.rawValue, ascending: false)]

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openClickedRow)

        let menu = NSMenu()
        let reveal = NSMenuItem(title: "Show in Finder", action: #selector(Coordinator.revealClickedRow), keyEquivalent: "")
        reveal.target = context.coordinator
        menu.addItem(reveal)
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(rows: rows, version: rowsVersion, folder: folder, selected: selected)
    }

    enum Column: String, CaseIterable {
        case name, size, modified, items

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

        var title: String {
            switch self {
            case .name: "Name"
            case .size: "Size"
            case .modified: "Modified"
            case .items: "Items"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 230
            case .size: 76
            case .modified: 84
            case .items: 64
            }
        }

        var minimumWidth: CGFloat {
            switch self {
            case .name: 120
            default: 56
            }
        }

        var isTextual: Bool { self == .name || self == .modified }
        var startsAscending: Bool { self == .name }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private let explorer: Explorer
        private var rows: [NodeRow] = []
        private var version = -1
        private var folder: NodeID?
        private var isApplying = false
        weak var table: NSTableView?

        init(explorer: Explorer) {
            self.explorer = explorer
        }

        func apply(rows: [NodeRow], version: Int, folder: NodeID, selected: NodeID?) {
            guard let table else { return }
            isApplying = true
            defer { isApplying = false }

            if version != self.version {
                self.rows = rows
                self.version = version
                table.reloadData()
            }
            if folder != self.folder {
                self.folder = folder
                table.scrollRowToVisible(0)
            }

            let shown = table.selectedRow >= 0 && table.selectedRow < self.rows.count ? self.rows[table.selectedRow].id : nil
            if shown != selected {
                if let selected, let row = self.rows.firstIndex(where: { $0.id == selected }) {
                    table.selectRowIndexes([row], byExtendingSelection: false)
                    table.scrollRowToVisible(row)
                } else {
                    table.deselectAll(nil)
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NodeCell
                ?? NodeCell(column: column)
            cell.show(rows[row], in: column)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let table else { return }
            explorer.selection = table.selectedRow >= 0 ? rows[table.selectedRow].id : nil
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let column = Column(rawValue: key)
            else { return }
            let sortKey: RowSort.Key = switch column {
            case .name: .name
            case .size: .allocated
            case .modified: .modified
            case .items: .items
            }
            explorer.sort = RowSort(key: sortKey, ascending: descriptor.ascending)
        }

        @objc func openClickedRow() {
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            let row = rows[table.clickedRow]
            if row.kind == .directory {
                explorer.show(row.id)
            }
        }

        @objc func revealClickedRow() {
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            revealInFinder(explorer.tree, rows[table.clickedRow].id)
        }
    }
}

/// Lays out its subviews by hand: Auto Layout in every cell was a large share of the
/// time spent changing folder.
private final class NodeCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon: NSImageView?

    init(column: NodeTableView.Column) {
        icon = column == .name ? NSImageView() : nil
        super.init(frame: .zero)
        identifier = column.identifier

        label.lineBreakMode = column == .name ? .byTruncatingMiddle : .byClipping
        label.alignment = column.isTextual ? .left : .right
        label.textColor = column == .modified || column == .items ? .secondaryLabelColor : .labelColor
        label.font = column.isTextual
            ? .systemFont(ofSize: NSFont.systemFontSize)
            : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        addSubview(label)

        if let icon {
            icon.contentTintColor = .secondaryLabelColor
            addSubview(icon)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("NodeCell is created in code only")
    }

    override func layout() {
        super.layout()
        var leading: CGFloat = 4
        if let icon {
            icon.frame = NSRect(x: leading, y: (bounds.height - 18) / 2, width: 18, height: 18)
            leading += 23
        }
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(
            x: leading,
            y: (bounds.height - height) / 2,
            width: max(0, bounds.width - leading - 4),
            height: height
        )
    }

    func show(_ row: NodeRow, in column: NodeTableView.Column) {
        switch column {
        case .name:
            label.stringValue = row.name
            icon?.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)
        case .size:
            label.stringValue = Format.bytes(row.allocated)
        case .modified:
            label.stringValue = Format.date(row.modified)
        case .items:
            label.stringValue = row.kind == .directory ? Format.count(row.items) : ""
        }
    }
}
