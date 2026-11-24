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
                    "Nothing to clean",
                    systemImage: "checkmark.circle",
                    description: Text("The folders iMemory knows how to clean safely are empty.")
                )
            } else {
                List {
                    if !safe.isEmpty {
                        Section {
                            ForEach(safe) { RuleRow(candidate: $0, model: model) }
                        } header: {
                            sectionHeader("Safe", detail: "Recreated at no cost.")
                        }
                    }
                    if !review.isEmpty {
                        Section {
                            ForEach(review) { RuleRow(candidate: $0, model: model) }
                        } header: {
                            sectionHeader("Review first", detail: "Recreated, but at a cost: read the description.")
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
                    Text("No items selected")
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
            Button("Clean…") {
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
                Text((candidate.rule.command == nil ? "" : "up to ") + Format.bytes(candidate.allocated))
                    .monospacedDigit()
            }
            Text(candidate.rule.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)

            if !blockers.isEmpty {
                Label("Quit \(blockers.joined(separator: ", ")) to clean this item", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.leading, 20)
            }

            Button {
                showsItems.toggle()
            } label: {
                Label(
                    candidate.rule.command == nil ? Format.items(candidate.itemCount) : "What it runs",
                    systemImage: showsItems ? "chevron.down" : "chevron.right"
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.leading, 20)
            .accessibilityLabel(showsItems ? "Hide items" : "Show items")

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
            Text("Delete \(Format.items(items))?")
                .font(.title2.weight(.medium))
            Text("They're deleted right away and don't go to the Trash: this can't be undone.")
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
                                Text((candidate.rule.command == nil ? "" : "up to ") + Format.bytes(candidate.allocated))
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
                                Text("Runs: \(command.displayText)")
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
                Button("Cancel", role: .cancel) {
                    model.phase = .choosing
                }
                .keyboardShortcut(.cancelAction)
                // Not the default action: Return must not delete anything.
                Button("Delete \(Format.items(items))", role: .destructive) {
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
            Text("Deleting")
                .font(.title3.weight(.medium))
            ProgressView(value: Double(progress.completedItems), total: Double(max(progress.totalItems, 1)))
            Text("\(Format.count(progress.completedItems)) of \(Format.count(progress.totalItems)) items")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Stop", action: cancel)
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
                Text("The disk is scanned again when you close this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: close)
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
                Text("\(Format.items(report.removedItemCount)) in the Trash")
                    .font(.title2.weight(.medium))
                Text("You can restore them from the Trash. The space is freed only when you empty it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(report.measuredFreed > 0 ? "\(Format.bytes(report.measuredFreed)) freed" : "No measurable space freed")
                    .font(.title2.weight(.medium))
                Text("Measured on disk. Estimate before deleting: \(Format.estimate(minimum: report.expectedPrivate, maximum: report.expectedAllocated)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !report.isTrashOperation, report.figuresDiverge {
                Text("The deleted files took up \(Format.bytes(report.removedBytes)). The difference may come from other apps writing to the disk, or from files that shared space with a clone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if report.wasCancelled {
                Text("Stopped: items already deleted can't be recovered.")
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
                        Text("\(report.isTrashOperation ? "In the Trash" : "Deleted"): \(Format.items(rule.removedItems.count))")
                            .foregroundStyle(.secondary)
                    }
                    if !rule.blockedBy.isEmpty {
                        Text("Not run: \(rule.blockedBy.joined(separator: ", ")) was open.")
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
                        Text("And \(Format.count(rule.issues.count - 20)) more problems.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
