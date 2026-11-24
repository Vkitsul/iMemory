import CleanKit
import RulesKit
import SwiftUI

struct CleanupView: View {
    @Bindable var model: CleanupModel
    let section: RuleSection

    private var shown: [CleanupCandidate] { model.candidates.filter { $0.rule.resolvedSection == section } }
    private var safe: [CleanupCandidate] { shown.filter { $0.rule.level == .safe } }
    private var review: [CleanupCandidate] { shown.filter { $0.rule.level == .review } }

    var body: some View {
        VStack(spacing: 0) {
            if shown.isEmpty {
                ContentUnavailableView(
                    "Niente da pulire",
                    systemImage: "checkmark.circle",
                    description: Text("Le cartelle che iMemory sa pulire in sicurezza sono vuote.")
                )
            } else {
                List {
                    if !safe.isEmpty {
                        Section {
                            ForEach(safe) { RuleRow(candidate: $0, model: model) }
                        } header: {
                            sectionHeader("Sicuro", detail: "Si ricrea senza conseguenze.")
                        }
                    }
                    if !review.isEmpty {
                        Section {
                            ForEach(review) { RuleRow(candidate: $0, model: model) }
                        } header: {
                            sectionHeader("Da valutare", detail: "Si ricrea, ma con un costo: leggi la descrizione.")
                        }
                    }
                }
                Divider()
                actionBar
            }
        }
        .onAppear { model.activeSection = section }
        .onChange(of: section) { model.activeSection = section }
        .task {
            // Closing a browser should unblock its rule without leaving this screen.
            while !Task.isCancelled {
                model.refreshRunningProcesses()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .sheet(isPresented: Binding(get: { model.isPresentingSheet }, set: { _ in })) {
            CleanupSheet(model: model)
                .interactiveDismissDisabled()
        }
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).textCase(nil)
        }
    }

    private var actionBar: some View {
        let selected = model.selectedCandidates.filter { $0.rule.resolvedSection == section }
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                if selected.isEmpty {
                    Text("Nessuna voce selezionata")
                } else {
                    Text(Format.spaceRange(
                        minimum: selected.map(\.privateBytes).reduce(0, +),
                        maximum: selected.map(\.allocated).reduce(0, +)
                    ))
                    .fontWeight(.medium)
                    Text(Format.items(selected.map(\.itemCount).reduce(0, +)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Pulisci…") {
                model.phase = .confirming
            }
            .controlSize(.large)
            .disabled(selected.isEmpty)
        }
        .padding(12)
    }
}

private struct RuleRow: View {
    let candidate: CleanupCandidate
    @Bindable var model: CleanupModel
    @State private var showsItems = false

    private var isOn: Binding<Bool> {
        Binding(
            get: { model.selectedIDs.contains(candidate.id) },
            set: { isSelected in
                if isSelected {
                    model.selectedIDs.insert(candidate.id)
                } else {
                    model.selectedIDs.remove(candidate.id)
                }
            }
        )
    }

    var body: some View {
        let blockers = model.blockingProcesses(of: candidate)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: isOn) {
                    Text(candidate.rule.title).fontWeight(.medium)
                }
                .toggleStyle(.checkbox)
                .disabled(!blockers.isEmpty)
                Spacer()
                Text((candidate.rule.command == nil ? "" : "fino a ") + Format.bytes(candidate.allocated))
                    .monospacedDigit()
            }
            Text(candidate.rule.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)

            if !blockers.isEmpty {
                Label("Chiudi \(blockers.joined(separator: ", ")) per pulire questa voce", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.leading, 20)
            }

            Button {
                showsItems.toggle()
            } label: {
                Label(
                    candidate.rule.command == nil ? Format.items(candidate.itemCount) : "Cosa esegue",
                    systemImage: showsItems ? "chevron.down" : "chevron.right"
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.leading, 20)
            .accessibilityLabel(showsItems ? "Nascondi le voci" : "Mostra le voci")

            if showsItems {
                if let command = candidate.rule.command {
                    Text(command.displayText)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.leading, 20)
                } else {
                    ItemList(roots: candidate.roots)
                        .frame(height: min(220, CGFloat(candidate.itemCount) * 20 + 8))
                        .padding(.leading, 20)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The exact list of what a rule removes.
private struct ItemList: View {
    let roots: [PlanRoot]

    private var rows: [(id: String, item: PlanItem)] {
        roots.flatMap { root in root.items.map { (id: root.path + "/" + $0.relativePath, item: $0) } }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(rows, id: \.id) { row in
                    HStack {
                        Text(row.id.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Format.bytes(row.item.allocated))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }
}

private struct CleanupSheet: View {
    @Bindable var model: CleanupModel

    var body: some View {
        Group {
            switch model.phase {
            case .choosing:
                EmptyView()
            case .confirming:
                ConfirmationView(model: model)
            case .running(let progress):
                RunningView(progress: progress) { model.cancelRun() }
            case .finished(let report):
                ReportView(report: report) { model.closeReport() }
            }
        }
        .frame(width: 560)
    }
}

private struct ConfirmationView: View {
    @Bindable var model: CleanupModel

    var body: some View {
        let selected = model.selectedCandidates
        let items = selected.map(\.itemCount).reduce(0, +)

        VStack(alignment: .leading, spacing: 14) {
            Text("Eliminare \(Format.items(items))?")
                .font(.title2.weight(.medium))
            Text("Vengono eliminate subito e non passano dal Cestino: l'operazione non si può annullare.")
                .fixedSize(horizontal: false, vertical: true)
            Text(Format.spaceRange(
                minimum: selected.map(\.privateBytes).reduce(0, +),
                maximum: selected.map(\.allocated).reduce(0, +)
            ))
            .fontWeight(.medium)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(selected) { candidate in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(candidate.rule.title).fontWeight(.medium)
                                Spacer()
                                Text((candidate.rule.command == nil ? "" : "fino a ") + Format.bytes(candidate.allocated))
                                    .monospacedDigit()
                            }
                            // The last chance to read what it costs, so it can't be left to the list.
                            if candidate.rule.level == .review {
                                Text(candidate.rule.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let command = candidate.rule.command {
                                Text("Esegue: \(command.displayText)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(candidate.roots, id: \.path) { root in
                                Text("\(root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")): \(Format.items(root.items.count))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)

            HStack {
                Spacer()
                Button("Annulla", role: .cancel) {
                    model.phase = .choosing
                }
                .keyboardShortcut(.cancelAction)
                // Not the default action: Return must not delete anything.
                Button("Elimina \(Format.items(items))", role: .destructive) {
                    model.confirm()
                }
            }
        }
        .padding(20)
    }
}

private struct RunningView: View {
    let progress: CleanupProgress
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Eliminazione in corso")
                .font(.title3.weight(.medium))
            ProgressView(value: Double(progress.completedItems), total: Double(max(progress.totalItems, 1)))
            Text("\(Format.count(progress.completedItems)) di \(Format.count(progress.totalItems)) voci")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Interrompi", action: cancel)
        }
        .padding(24)
    }
}

struct ReportView: View {
    let report: CleanupReport
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ReportSummary(report: report)

            ScrollView {
                ReportDetails(report: report)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)

            HStack {
                Text("Alla chiusura il disco viene scansionato di nuovo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Chiudi", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

/// The result of a cleanup, shared by the report and the history.
struct ReportSummary: View {
    let report: CleanupReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if report.isTrashOperation {
                Text("\(Format.items(report.removedItemCount)) nel Cestino")
                    .font(.title2.weight(.medium))
                Text("Si possono ripristinare dal Cestino. Lo spazio si libera solo svuotandolo.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(report.measuredFreed > 0 ? "\(Format.bytes(report.measuredFreed)) liberati" : "Nessuno spazio liberato in modo misurabile")
                    .font(.title2.weight(.medium))
                Text("Misurati sul disco. Stima prima di eliminare: \(Format.estimate(minimum: report.expectedPrivate, maximum: report.expectedAllocated)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !report.isTrashOperation, report.figuresDiverge {
                Text("I file eliminati occupavano \(Format.bytes(report.removedBytes)). La differenza può dipendere da altre app che scrivevano sul disco, o da file che condividevano spazio con un clone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if report.wasCancelled {
                Text("Interrotta: le voci già eliminate non si recuperano.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct ReportDetails: View {
    let report: CleanupReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(report.rules) { rule in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(rule.title).fontWeight(.medium)
                        Spacer()
                        Text("\(report.isTrashOperation ? "Nel Cestino" : "Eliminate"): \(Format.items(rule.removedItems.count))")
                            .foregroundStyle(.secondary)
                    }
                    if !rule.blockedBy.isEmpty {
                        Text("Non eseguita: \(rule.blockedBy.joined(separator: ", ")) era aperto.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(Array(rule.issues.prefix(20).enumerated()), id: \.offset) { _, issue in
                        Text("\(issue.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")): \(issue.problem.message)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                    if rule.issues.count > 20 {
                        Text("E altri \(Format.count(rule.issues.count - 20)) problemi.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
