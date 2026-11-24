import CleanKit
import ScanKit
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                Label("Overview", systemImage: "chart.pie").tag(AppModel.Section.overview)
                Label("Explore", systemImage: "square.grid.3x3.square").tag(AppModel.Section.explore)
                Label("Apps", systemImage: "app.badge").tag(AppModel.Section.apps)
                Label("Large files", systemImage: "doc.badge.ellipsis").tag(AppModel.Section.files)
                Label("Duplicates", systemImage: "doc.on.doc").tag(AppModel.Section.duplicates)
                Label("Cleanup", systemImage: "sparkles").tag(AppModel.Section.cleanup)
                Label("Developer", systemImage: "hammer").tag(AppModel.Section.developer)
                Label("History", systemImage: "clock").tag(AppModel.Section.history)
                Label("Automation", systemImage: "gearshape.2").tag(AppModel.Section.automation)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Scan again", systemImage: "arrow.clockwise") {
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
                Label("No scan yet", systemImage: "internaldrive")
            } description: {
                Text("Measure the disk to see where the space goes. Scanning only reads.")
            } actions: {
                Button("Scan") { model.startScan() }
            }
        case .scanning(let progress):
            ScanningView(progress: progress, isStalled: model.isScanStalled) { model.cancelScan() }
        case .failed(let message):
            ContentUnavailableView {
                Label("The scan failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { model.startScan() }
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
            Text("Scanning the disk")
                .font(.title3)
            Text("\(Format.count(progress.items)) items, \(Format.bytes(progress.allocatedBytes))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if isStalled {
                Label("The scan has stalled. macOS may be waiting for an answer to a permission request: check for an open alert.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Cancel", action: cancel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
