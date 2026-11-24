import CleanKit
import ScanKit
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                Label("Panoramica", systemImage: "chart.pie").tag(AppModel.Section.overview)
                Label("Esplora", systemImage: "square.grid.3x3.square").tag(AppModel.Section.explore)
                Label("App", systemImage: "app.badge").tag(AppModel.Section.apps)
                Label("File grandi", systemImage: "doc.badge.ellipsis").tag(AppModel.Section.files)
                Label("Duplicati", systemImage: "doc.on.doc").tag(AppModel.Section.duplicates)
                Label("Pulizia", systemImage: "sparkles").tag(AppModel.Section.cleanup)
                Label("Sviluppatore", systemImage: "hammer").tag(AppModel.Section.developer)
                Label("Cronologia", systemImage: "clock").tag(AppModel.Section.history)
                Label("Automazione", systemImage: "gearshape.2").tag(AppModel.Section.automation)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Scansiona di nuovo", systemImage: "arrow.clockwise") {
                            model.startScan()
                        }
                        .keyboardShortcut("r")
                        .disabled(model.isScanning)
                    }
                }
        }
        .navigationTitle("iMemory")
    }

    @ViewBuilder
    private var detail: some View {
        // History comes from disk, so it doesn't need a scan.
        if model.section == .history, model.session == nil {
            HistoryView(history: model.cleanup.history)
        } else {
            scanDependentDetail
        }
    }

    @ViewBuilder
    private var scanDependentDetail: some View {
        switch model.phase {
        case .idle:
            ContentUnavailableView {
                Label("Nessuna scansione", systemImage: "internaldrive")
            } description: {
                Text("Misura il disco per vedere dove finisce lo spazio. La scansione legge soltanto.")
            } actions: {
                Button("Scansiona") { model.startScan() }
            }
        case .scanning(let progress):
            ScanningView(progress: progress, isStalled: model.isScanStalled) { model.cancelScan() }
        case .failed(let message):
            ContentUnavailableView {
                Label("La scansione non è riuscita", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Riprova") { model.startScan() }
            }
        case .ready(let session):
            switch model.section {
            case .overview:
                OverviewView(
                    session: session,
                    open: { model.open($0) },
                    openCleanup: { model.section = $0 == .developer ? .developer : .cleanup }
                )
            case .explore:
                if let explorer = model.explorer {
                    ExploreView(explorer: explorer)
                }
            case .apps:
                AppsView(apps: session.apps, trash: model.trash)
            case .files:
                LargeFilesView(files: session.largeFiles, trash: model.trash)
            case .duplicates:
                DuplicatesView(
                    model: model.duplicates,
                    trash: model.trash,
                    tree: session.tree,
                    homeInTree: String(NSHomeDirectory().drop { $0 == "/" })
                )
            case .automation:
                AutomationView(model: model.automation, eligible: ScheduledCleanup.eligible(session.candidates))
            case .cleanup:
                CleanupView(model: model.cleanup, section: .general)
            case .developer:
                CleanupView(model: model.cleanup, section: .developer)
            case .history:
                HistoryView(history: model.cleanup.history)
            }
        }
    }
}

private struct ScanningView: View {
    let progress: ScanProgress
    let isStalled: Bool
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Scansione del disco")
                .font(.title3)
            Text("\(Format.count(progress.items)) voci, \(Format.bytes(progress.allocatedBytes))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if isStalled {
                Label("La scansione è ferma. macOS potrebbe aspettare una risposta a una richiesta di permesso: controlla se c'è un avviso aperto.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Annulla", action: cancel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
