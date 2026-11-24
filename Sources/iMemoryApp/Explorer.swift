import Foundation
import Observation
import ScanKit

/// Nonisolated because the sort key paths in `Explorer.sortOrder` must be sendable.
nonisolated struct NodeRow: Identifiable, Sendable {
    let id: NodeID
    let name: String
    let kind: NodeKind
    let allocated: Int64
    let modified: Date
    let items: Int

    init(tree: FileTree, node: NodeID) {
        id = node
        name = tree.name(of: node)
        kind = tree.kind(of: node)
        allocated = tree.sizes(of: node).allocated
        modified = tree.modificationDate(of: node)
        items = tree.descendantCount(of: node)
    }
}

nonisolated enum KindFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case folders = "Folders"
    case files = "Files"

    var id: Self { self }
}

enum AgeFilter: String, CaseIterable, Identifiable {
    case any = "Any date"
    case oneMonth = "Over 1 month ago"
    case sixMonths = "Over 6 months ago"
    case oneYear = "Over 1 year ago"

    var id: Self { self }

    var maximumDate: Date? {
        let calendar = Calendar.current
        return switch self {
        case .any: nil
        case .oneMonth: calendar.date(byAdding: .month, value: -1, to: .now)
        case .sixMonths: calendar.date(byAdding: .month, value: -6, to: .now)
        case .oneYear: calendar.date(byAdding: .year, value: -1, to: .now)
        }
    }
}

enum SizeFilter: String, CaseIterable, Identifiable {
    case any = "Any size"
    case oneMB = "Over 1 MB"
    case hundredMB = "Over 100 MB"
    case oneGB = "Over 1 GB"

    var id: Self { self }

    var minimumBytes: Int64 {
        switch self {
        case .any: 0
        case .oneMB: 1_000_000
        case .hundredMB: 100_000_000
        case .oneGB: 1_000_000_000
        }
    }
}

nonisolated struct RowSort: Sendable {
    enum Key: Sendable {
        case name, allocated, modified, items
    }

    var key: Key
    var ascending: Bool
}

/// What to show out of a folder's items. Plain data, so it can run off the main actor.
nonisolated struct RowQuery: Sendable {
    let kind: KindFilter
    let maximumDate: Date?
    let minimumBytes: Int64
    let search: String
    let sort: RowSort

    func arranged(_ rows: [NodeRow]) -> [NodeRow] {
        var result = rows.filter { row in
            switch kind {
            case .all: break
            case .folders: guard row.kind == .directory else { return false }
            case .files: guard row.kind != .directory else { return false }
            }
            if let maximumDate, row.modified > maximumDate { return false }
            if row.allocated < minimumBytes { return false }
            if !search.isEmpty, !row.name.localizedCaseInsensitiveContains(search) { return false }
            return true
        }

        let ascending = sort.ascending
        switch sort.key {
        case .name:
            result.sort { ($0.name.localizedStandardCompare($1.name) == .orderedAscending) == ascending }
        case .allocated:
            result.sort { ascending ? $0.allocated < $1.allocated : $0.allocated > $1.allocated }
        case .modified:
            result.sort { ascending ? $0.modified < $1.modified : $0.modified > $1.modified }
        case .items:
            result.sort { ascending ? $0.items < $1.items : $0.items > $1.items }
        }
        return result
    }

    @concurrent
    func arrangedInBackground(_ rows: [NodeRow]) async -> [NodeRow] {
        arranged(rows)
    }
}

/// What the Explore section is showing: one folder, its filtered items, and a selection.
@Observable
final class Explorer {
    let tree: FileTree
    private(set) var current: NodeID
    private(set) var breadcrumb: [NodeID] = []
    private(set) var visibleRows: [NodeRow] = []
    /// Changes whenever `visibleRows` does, so the table can tell without comparing them.
    private(set) var rowsVersion = 0
    /// May be an item nested inside a child of `current`, picked from the treemap.
    var selection: NodeID?

    var kindFilter = KindFilter.all { didSet { refreshRows() } }
    var ageFilter = AgeFilter.any { didSet { refreshRows() } }
    var sizeFilter = SizeFilter.any { didSet { refreshRows() } }
    var searchText = "" { didSet { refreshRows() } }
    var sort = RowSort(key: .allocated, ascending: false) { didSet { refreshRows() } }
    /// True while a large folder is being sorted or filtered in the background.
    private(set) var isRefreshing = false

    private var allRows: [NodeRow] = []
    private var refreshTask: Task<Void, Never>?
    /// Below this size, sorting is fast enough to do without leaving the main actor.
    private static let backgroundThreshold = 5000

    init(tree: FileTree) {
        self.tree = tree
        current = tree.root
        show(tree.root)
    }

    /// The child of `current` to highlight in the list for the current selection.
    var listSelection: NodeID? {
        get {
            var node = selection
            while let candidate = node {
                let parent = tree.parent(of: candidate)
                if parent == current { return candidate }
                node = parent
            }
            return nil
        }
        set { selection = newValue }
    }

    /// Opens `node`, or its parent with `node` selected if it isn't a folder.
    func show(_ node: NodeID) {
        if tree.kind(of: node) == .directory {
            current = node
            selection = nil
        } else if let parent = tree.parent(of: node) {
            current = parent
            selection = node
        }

        var chain: [NodeID] = []
        var cursor: NodeID? = current
        while let step = cursor {
            chain.append(step)
            cursor = tree.parent(of: step)
        }
        breadcrumb = chain.reversed()

        allRows = tree.children(of: current).map { NodeRow(tree: tree, node: $0) }
        refreshRows()
    }

    func goUp() {
        if let parent = tree.parent(of: current) {
            let previous = current
            show(parent)
            selection = previous
        }
    }

    var canGoUp: Bool { tree.parent(of: current) != nil }

    private func refreshRows() {
        let query = RowQuery(
            kind: kindFilter,
            maximumDate: ageFilter.maximumDate,
            minimumBytes: sizeFilter.minimumBytes,
            search: searchText,
            sort: sort
        )
        let rows = allRows

        refreshTask?.cancel()
        guard rows.count > Self.backgroundThreshold else {
            isRefreshing = false
            publish(query.arranged(rows))
            return
        }

        isRefreshing = true
        refreshTask = Task {
            let arranged = await query.arrangedInBackground(rows)
            // A newer request supersedes this one and will publish its own result.
            guard !Task.isCancelled else { return }
            isRefreshing = false
            publish(arranged)
        }
    }

    private func publish(_ rows: [NodeRow]) {
        visibleRows = rows
        rowsVersion += 1
    }
}
