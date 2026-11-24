import AppKit
import DuplicateKit
import Observation
import ScanKit
import Synchronization
import SwiftUI

/// The search for duplicates, which runs only when asked because it reads files.
@Observable
final class DuplicatesModel {
    enum Phase {
        case idle
        case searching(DuplicateProgress)
        case finished(DuplicateSearchResult)
    }

    private(set) var phase = Phase.idle
    var selected = Set<String>()

    private var task: Task<Void, Never>?
    private var searchFlag: CancelFlag?

    var groups: [DuplicateGroup] {
        if case .finished(let result) = phase { result.groups } else { [] }
    }

    /// Results describe the disk at the time of the search, so a new scan discards them.
    func reset() {
        stopSearch()
        task?.cancel()
        phase = .idle
        selected = []
    }

    func search(tree: FileTree, homeInTree: String) {
        stopSearch()
        let flag = CancelFlag()
        searchFlag = flag
        selected = []
        phase = .searching(DuplicateProgress(filesRead: 0, filesToRead: 0, bytesRead: 0))

        task = Task {
            let latest = LatestDuplicateProgress()
            let poll = Task {
                while !Task.isCancelled {
                    if let progress = latest.value {
                        phase = .searching(progress)
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            let result = await Self.run(tree: tree, homeInTree: homeInTree, latest: latest, flag: flag)
            poll.cancel()
            // A newer search or a reset has taken over, and this result is stale.
            guard searchFlag === flag, !Task.isCancelled else { return }
            phase = .finished(result)
        }
    }

    func stopSearch() {
        searchFlag?.set(true)
    }

    /// False if it would leave a group without any copy. The list uses it to disable the box.
    func canSelect(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        if selected.contains(file.id) { return true }
        return group.files.filter { selected.contains($0.id) }.count < group.files.count - 1
    }

    @concurrent
    private static func run(
        tree: FileTree,
        homeInTree: String,
        latest: LatestDuplicateProgress,
        flag: CancelFlag
    ) async -> DuplicateSearchResult {
        DuplicateFinder.find(
            tree: tree,
            homeInTree: homeInTree,
            realRoot: "",
            progress: { latest.value = $0 },
            isCancelled: { flag.value }
        )
    }
}

nonisolated final class CancelFlag: Sendable {
    private let storage = Atomic<Bool>(false)
    var value: Bool { storage.load(ordering: .relaxed) }
    func set(_ newValue: Bool) { storage.store(newValue, ordering: .relaxed) }
}

nonisolated final class LatestDuplicateProgress: Sendable {
    private let storage = Mutex<DuplicateProgress?>(nil)

    var value: DuplicateProgress? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

struct DuplicatesView: View {
    @Bindable var model: DuplicatesModel
    @Bindable var trash: TrashModel
    let tree: FileTree
    let homeInTree: String

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                ContentUnavailableView {
                    Label("Find duplicate files", systemImage: "doc.on.doc")
                } description: {
                    Text("Compares the content of files over 1 MB in your home folder, outside the Library and hidden folders. APFS clones don't count: they don't take up space twice. Only reads.")
                } actions: {
                    Button("Search") { model.search(tree: tree, homeInTree: homeInTree) }
                }
            case .searching(let progress):
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Comparing files")
                        .font(.title3)
                    Text("\(Format.count(progress.filesRead)) of \(Format.count(progress.filesToRead)) files, \(Format.bytes(progress.bytesRead)) read")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Stop") { model.stopSearch() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .finished(let result):
                results(result)
            }
        }
        .sheet(isPresented: Binding(get: { trash.isPresentingSheet }, set: { _ in })) {
            TrashSheet(trash: trash, app: nil)
                .interactiveDismissDisabled()
        }
    }

    @ViewBuilder
    private func results(_ result: DuplicateSearchResult) -> some View {
        if result.groups.isEmpty {
            ContentUnavailableView {
                Label(result.wasCancelled ? "Search stopped" : "No duplicates", systemImage: "checkmark.circle")
            } description: {
                Text(result.wasCancelled
                    ? "The search was stopped before finding any duplicates."
                    : "Among \(Format.count(result.filesConsidered)) files over 1 MB, no copies take up space twice.")
            } actions: {
                Button("Search again") { model.search(tree: tree, homeInTree: homeInTree) }
            }
        } else {
            VStack(spacing: 0) {
                List(result.groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            DuplicateRow(file: file, group: group, model: model)
                        }
                    } header: {
                        Text("\(group.copies) copies: \(Format.bytes(group.reclaimable)) to recover")
                            .textCase(nil)
                    }
                }
                Divider()
                actionBar(result)
            }
        }
    }

    private func actionBar(_ result: DuplicateSearchResult) -> some View {
        let selection = try? DuplicateSelection(groups: result.groups, selected: model.selected)
        let count = selection?.toRemove.count ?? 0

        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(count == 0 ? "No files selected" : "\(Format.items(count)) to move")
                    .fontWeight(count == 0 ? .regular : .medium)
                if result.wasCancelled {
                    Text("Search stopped: the results are partial.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if result.unreadableFiles > 0 {
                    Text("\(Format.count(result.unreadableFiles)) unreadable files are left out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Choose the copies to remove. At least one always stays.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Move to Trash…") {
                if let selection {
                    trash.prepareDuplicates(selection)
                }
            }
            .controlSize(.large)
            .disabled(count == 0)
        }
        .padding(12)
    }
}

private struct DuplicateRow: View {
    let file: DuplicateFile
    let group: DuplicateGroup
    @Bindable var model: DuplicatesModel

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Select \(URL(fileURLWithPath: file.path).lastPathComponent)", isOn: Binding(
                get: { model.selected.contains(file.id) },
                set: { isOn in
                    if isOn {
                        model.selected.insert(file.id)
                    } else {
                        model.selected.remove(file.id)
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!model.canSelect(file, in: group))

            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: file.path).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(URL(fileURLWithPath: file.path).deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if file.isClone {
                    Text("Clone: shares space with another item in the group")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text(Format.date(file.modified))
                .foregroundStyle(.secondary)
            Text(Format.bytes(file.allocated))
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
        }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            }
        }
    }
}
