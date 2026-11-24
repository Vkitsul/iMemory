import AppKit
import AppsKit
import CleanKit
import ScanKit
import SwiftUI

struct AppsView: View {
    let apps: [InstalledApp]
    @Bindable var trash: TrashModel

    @State private var searchText = ""
    @State private var running = Set<String>()

    private var visibleApps: [InstalledApp] {
        searchText.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var selected: InstalledApp? {
        apps.first { $0.id == trash.selectedAppID }
    }

    var body: some View {
        HSplitView {
            List(visibleApps, selection: $trash.selectedAppID) { app in
                AppRow(app: app)
            }
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 460, maxHeight: .infinity)

            Group {
                if let selected {
                    AppDetail(app: selected, isRunning: isRunning(selected)) {
                        trash.prepareUninstall(selected)
                    }
                    .id(selected.id)
                } else {
                    ContentUnavailableView(
                        "Scegli un'app",
                        systemImage: "app.dashed",
                        description: Text("Vedi quanto occupa, cosa ha lasciato nella Libreria e quanto spazio torna togliendola.")
                    )
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Cerca un'app")
        .task {
            while !Task.isCancelled {
                running = RunningProcesses.names()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .sheet(isPresented: Binding(get: { trash.isPresentingSheet }, set: { _ in })) {
            TrashSheet(trash: trash, app: selected)
                .interactiveDismissDisabled()
        }
    }

    private func isRunning(_ app: InstalledApp) -> Bool {
        app.executable.map { RunningProcesses.contains($0, in: running) } ?? false
    }
}

private struct AppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .lineLimit(1)
                Text(lastUsedText(app.lastUsed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(Format.bytes(app.allocated + app.leftoversSize))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Spotlight often has no record of an app, and that must never read as "never used".
private func lastUsedText(_ date: Date?) -> String {
    date.map { "Usata il \(Format.date($0))" } ?? "Ultimo utilizzo non noto"
}

private struct AppDetail: View {
    let app: InstalledApp
    let isRunning: Bool
    let uninstall: () -> Void

    @State private var estimate: RecoveryEstimate?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name)
                            .font(.title2.weight(.medium))
                        if let version = app.version {
                            Text("Versione \(version)")
                                .foregroundStyle(.secondary)
                        }
                        Text(lastUsedText(app.lastUsed))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 0) {
                    row("App", value: Format.bytes(app.allocated))
                    Divider()
                    row("Nella Libreria", value: Format.bytes(app.leftoversSize))
                    Divider()
                    row("Solo l'app, spazio che torna", value: estimate.map { Format.bytes($0.recoverable) } ?? "Calcolo…")
                        .help("Più basso di quanto occupa se condivide spazio con altri file tramite cloni APFS.")
                }
                .background(.background.secondary, in: .rect(cornerRadius: 8))

                if !app.leftovers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nella Libreria")
                            .font(.headline)
                        VStack(spacing: 0) {
                            ForEach(app.leftovers) { leftover in
                                LeftoverRow(leftover: leftover)
                                if leftover.id != app.leftovers.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .background(.background.secondary, in: .rect(cornerRadius: 8))
                    }
                }

                HStack {
                    Button("Mostra nel Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                    }
                    Spacer()
                    if isRunning {
                        Text("Chiudi \(app.name) per disinstallarla")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    Button("Disinstalla…", action: uninstall)
                        .disabled(isRunning)
                }
            }
            .padding(20)
        }
        .task(id: app.id) {
            estimate = nil
            estimate = await Self.computeEstimate(path: app.path)
        }
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @concurrent
    private static func computeEstimate(path: String) async -> RecoveryEstimate {
        RecoveryEstimator.estimate(paths: [path])
    }
}

private struct LeftoverRow: View {
    let leftover: Leftover

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(leftover.path.replacingOccurrences(of: NSHomeDirectory() + "/Library/", with: ""))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(description(of: leftover))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(Format.bytes(leftover.allocated))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

func description(of leftover: Leftover) -> String {
    let kind = switch leftover.kind {
    case .cache: "File temporanei"
    case .settings: "Impostazioni"
    case .data: "Dati dell'app: possono contenere il tuo lavoro"
    }
    return leftover.matchedByIdentifier ? kind : "\(kind). Trovato solo per nome: potrebbe appartenere ad altro"
}

/// Confirmation, progress, and report for anything going to the Trash.
struct TrashSheet: View {
    @Bindable var trash: TrashModel
    /// The app being uninstalled, if any, to offer the choice of leftovers.
    let app: InstalledApp?

    var body: some View {
        Group {
            switch trash.phase {
            case .idle:
                EmptyView()
            case .confirming(let request):
                confirmation(request)
            case .running:
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Spostamento nel Cestino")
                }
                .padding(30)
            case .finished(let report):
                ReportView(report: report) { trash.closeReport() }
            }
        }
        .frame(width: 560)
    }

    private func confirmation(_ request: TrashModel.Request) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.executable == nil ? "Spostare \(Format.items(request.items.count)) nel Cestino?" : "Disinstallare \(request.title)?")
                .font(.title2.weight(.medium))
            Text("Vanno nel Cestino, da cui si possono ripristinare. Lo spazio si libera solo svuotandolo.")
                .fixedSize(horizontal: false, vertical: true)
            if let note = request.note {
                Text(note)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let app, request.executable != nil {
                        Text(app.path)
                            .font(.callout.weight(.medium))
                        ForEach(app.leftovers) { leftover in
                            Toggle(isOn: Binding(
                                get: { trash.selectedLeftovers.contains(leftover.id) },
                                set: { isOn in
                                    if isOn {
                                        trash.selectedLeftovers.insert(leftover.id)
                                    } else {
                                        trash.selectedLeftovers.remove(leftover.id)
                                    }
                                    trash.updateUninstall(app)
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(leftover.path.replacingOccurrences(of: NSHomeDirectory() + "/Library/", with: ""))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text("\(Format.bytes(leftover.allocated)). \(description(of: leftover))")
                                        .font(.caption)
                                        .foregroundStyle(leftover.kind == .data ? .orange : .secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    } else {
                        ForEach(request.items) { item in
                            HStack {
                                Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(Format.bytes(item.allocated))
                                    .font(.callout)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)

            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { trash.cancel() }
                    .keyboardShortcut(.cancelAction)
                // Not the default action: Return must not move anything.
                Button("Sposta nel Cestino", role: .destructive) { trash.confirm() }
            }
        }
        .padding(20)
    }
}
