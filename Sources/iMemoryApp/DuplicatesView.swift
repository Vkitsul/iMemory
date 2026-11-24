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
                    Label("Cerca i file duplicati", systemImage: "doc.on.doc")
                } description: {
                    Text("Confronta il contenuto dei file oltre 1 MB nella tua cartella, fuori dalla Libreria e dalle cartelle nascoste. I cloni APFS non contano: non occupano spazio doppio. Legge soltanto.")
                } actions: {
                    Button("Cerca") { model.search(tree: tree, homeInTree: homeInTree) }
                }
            case .searching(let progress):
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Confronto dei file")
                        .font(.title3)
                    Text("\(Format.count(progress.filesRead)) di \(Format.count(progress.filesToRead)) file, \(Format.bytes(progress.bytesRead)) letti")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Interrompi") { model.stopSearch() }
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
                Label(result.wasCancelled ? "Ricerca interrotta" : "Nessun duplicato", systemImage: "checkmark.circle")
            } description: {
                Text(result.wasCancelled
                    ? "La ricerca è stata interrotta prima di trovare duplicati."
                    : "Fra \(Format.count(result.filesConsidered)) file oltre 1 MB non ci sono copie che occupano spazio doppio.")
            } actions: {
                Button("Cerca di nuovo") { model.search(tree: tree, homeInTree: homeInTree) }
            }
        } else {
            VStack(spacing: 0) {
                List(result.groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            DuplicateRow(file: file, group: group, model: model)
                        }
                    } header: {
                        Text("\(group.copies) copie: si recuperano \(Format.bytes(group.reclaimable))")
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
                Text(count == 0 ? "Nessun file selezionato" : "\(Format.items(count)) da spostare")
                    .fontWeight(count == 0 ? .regular : .medium)
                if result.wasCancelled {
                    Text("Ricerca interrotta: i risultati sono parziali.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if result.unreadableFiles > 0 {
                    Text("\(Format.count(result.unreadableFiles)) file non leggibili sono esclusi.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Scegli le copie da togliere. Almeno una resta sempre.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Sposta nel Cestino…") {
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
            Toggle("Seleziona \(URL(fileURLWithPath: file.path).lastPathComponent)", isOn: Binding(
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
                    Text("Clone: condivide spazio con un'altra voce del gruppo")
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
            Button("Mostra nel Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            }
        }
    }
}
