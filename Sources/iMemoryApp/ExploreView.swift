import ScanKit
import SwiftUI

struct ExploreView: View {
    @Bindable var explorer: Explorer
    @State private var showsDetails = true

    var body: some View {
        VStack(spacing: 0) {
            Breadcrumb(explorer: explorer)
            Divider()
            HSplitView {
                TreemapView(explorer: explorer)
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                NodeTable(explorer: explorer)
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $explorer.searchText, placement: .toolbar, prompt: "Search this folder")
        .inspector(isPresented: $showsDetails) {
            DetailsPanel(explorer: explorer)
                .inspectorColumnWidth(min: 220, ideal: 260, max: 340)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Enclosing folder", systemImage: "chevron.up") {
                    explorer.goUp()
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!explorer.canGoUp)
            }
            ToolbarItem {
                Menu("Filters", systemImage: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") {
                    Picker("Kind", selection: $explorer.kindFilter) {
                        ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Last modified", selection: $explorer.ageFilter) {
                        ForEach(AgeFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Size", selection: $explorer.sizeFilter) {
                        ForEach(SizeFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            ToolbarItem {
                Button("Details", systemImage: "sidebar.right") {
                    showsDetails.toggle()
                }
            }
        }
    }

    private var filtersActive: Bool {
        explorer.kindFilter != .all || explorer.ageFilter != .any || explorer.sizeFilter != .any
    }
}

private struct Breadcrumb: View {
    let explorer: Explorer

    var body: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(explorer.breadcrumb, id: \.self) { node in
                        if node != explorer.tree.root {
                            Image(systemName: "chevron.compact.right")
                                .foregroundStyle(.tertiary)
                        }
                        Button(title(of: node)) {
                            explorer.show(node)
                        }
                        .buttonStyle(.plain)
                        .fontWeight(node == explorer.current ? .medium : .regular)
                        .foregroundStyle(node == explorer.current ? .primary : .secondary)
                    }
                }
            }
            .scrollIndicators(.never)
            Text(Format.bytes(explorer.tree.sizes(of: explorer.current).allocated))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func title(of node: NodeID) -> String {
        node == explorer.tree.root ? "Macintosh HD" : explorer.tree.name(of: node)
    }
}

private struct NodeTable: View {
    let explorer: Explorer

    var body: some View {
        NodeTableView(
            explorer: explorer,
            rows: explorer.visibleRows,
            rowsVersion: explorer.rowsVersion,
            folder: explorer.current,
            selected: explorer.listSelection
        )
        .overlay {
            if explorer.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.regularMaterial, in: .rect(cornerRadius: 8))
            } else if explorer.visibleRows.isEmpty {
                ContentUnavailableView("No items", systemImage: "line.3.horizontal.decrease.circle", description: Text("The folder is empty, or the filters hide everything."))
            }
        }
    }
}

private struct DetailsPanel: View {
    let explorer: Explorer

    private var node: NodeID { explorer.selection ?? explorer.current }

    var body: some View {
        let tree = explorer.tree
        let sizes = tree.sizes(of: node)
        let flags = tree.flags(of: node)

        Form {
            Section {
                Text(node == tree.root ? "Macintosh HD" : tree.name(of: node))
                    .font(.headline)
                    .lineLimit(3)
                Text(Format.displayPath(tree.path(of: node)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            Section("Sizes") {
                LabeledContent("On disk", value: Format.bytes(sizes.allocated))
                    .help("The space it takes up, as du reports it.")
                LabeledContent("Content", value: Format.bytes(sizes.logical))
                    .help("The length of the files, before compression and without shared space.")
                LabeledContent("Private", value: Format.bytes(sizes.privateBytes))
                    .help("Space not shared with APFS clones. Deleting this item frees at least this much.")
            }
            Section("Info") {
                LabeledContent("Modified", value: Format.date(tree.modificationDate(of: node)))
                if tree.kind(of: node) == .directory {
                    LabeledContent("Items", value: Format.count(tree.descendantCount(of: node)))
                }
            }
            if !flags.isEmpty {
                Section("Notes") {
                    if flags.contains(.unreadable) {
                        Text("Unreadable: its content isn't in the totals.")
                    }
                    if flags.contains(.dataless) {
                        Text("Cloud only: takes no space on this Mac and wasn't downloaded.")
                    }
                    if flags.contains(.hardLinkDuplicate) {
                        Text("Hard link: its space is counted at another path.")
                    }
                    if flags.contains(.mountPoint) {
                        Text("Another volume is mounted here, and isn't measured.")
                    }
                }
            }
            Section {
                Button("Show in Finder") {
                    revealInFinder(tree, node)
                }
            }
        }
        .formStyle(.grouped)
    }
}

func revealInFinder(_ tree: FileTree, _ node: NodeID) {
    let url = URL(fileURLWithPath: Format.displayPath(tree.path(of: node)))
    NSWorkspace.shared.activateFileViewerSelecting([url])
}
