import AppKit
import AppsKit
import CleanKit
import DuplicateKit
import Foundation
import Observation
import ScanKit

/// Moving personal items to the Trash, from a confirmation to the final report.
@Observable
final class TrashModel {
    struct Request {
        let title: String
        let items: [TrashItem]
        let executable: String?
        /// Why some of the items are included, shown with the confirmation.
        let note: String?
        /// Copies that have to stay for the move to go ahead.
        var mustRemain: [TrashItem] = []
    }

    enum Phase {
        case idle
        case confirming(Request)
        case running
        case finished(CleanupReport)
    }

    private(set) var phase = Phase.idle
    /// Called when the user closes the report, since the disk has changed.
    var onFinished: (CleanupReport) -> Void = { _ in }

    private let mover: TrashMover
    /// What each app's confirmation offers, kept while the user chooses.
    var selectedLeftovers = Set<String>()
    /// The app open in the Apps section.
    var selectedAppID: String?

    init(
        policy: TrashPolicy = TrashPolicy(
            home: NSHomeDirectory(),
            appFolders: ["/Applications", NSHomeDirectory() + "/Applications"]
        ),
        moveToTrash: (@Sendable (URL) throws -> Void)? = nil
    ) {
        if let moveToTrash {
            mover = TrashMover(policy: policy, moveToTrash: moveToTrash)
        } else {
            mover = TrashMover(policy: policy)
        }
    }

    var isPresentingSheet: Bool {
        if case .idle = phase { false } else { true }
    }

    func prepareUninstall(_ app: InstalledApp) {
        selectedLeftovers = Set(app.leftovers.filter(\.isSelectedByDefault).map(\.id))
        let chosen = app.leftovers.filter { selectedLeftovers.contains($0.id) }
        phase = .confirming(Request(
            title: app.name,
            items: [TrashItem(path: app.path, fileID: app.fileID, allocated: app.allocated, kind: .app)]
                + chosen.map { TrashItem(path: $0.path, fileID: $0.fileID, allocated: $0.allocated, kind: .leftover) },
            executable: app.executable,
            note: nil
        ))
    }

    func prepareFiles(_ files: [LargeFile]) {
        phase = .confirming(Request(
            title: "File grandi",
            items: files.map { TrashItem(path: $0.path, fileID: $0.fileID, allocated: $0.allocated, kind: .file) },
            executable: nil,
            note: nil
        ))
    }

    func prepareDuplicates(_ selection: DuplicateSelection) {
        func item(_ file: DuplicateFile) -> TrashItem {
            TrashItem(path: file.path, fileID: file.fileID, allocated: file.allocated, kind: .file)
        }
        phase = .confirming(Request(
            title: "Duplicati",
            items: selection.toRemove.map(item),
            executable: nil,
            note: "Resta una copia per gruppo. Se manca al momento di spostare, non si sposta nulla.",
            mustRemain: selection.toKeep.map(item)
        ))
    }

    /// Replaces the leftovers in a pending uninstall after the user changes the selection.
    func updateUninstall(_ app: InstalledApp) {
        guard case .confirming(let request) = phase else { return }
        let chosen = app.leftovers.filter { selectedLeftovers.contains($0.id) }
        phase = .confirming(Request(
            title: request.title,
            items: [TrashItem(path: app.path, fileID: app.fileID, allocated: app.allocated, kind: .app)]
                + chosen.map { TrashItem(path: $0.path, fileID: $0.fileID, allocated: $0.allocated, kind: .leftover) },
            executable: request.executable,
            note: request.note
        ))
    }

    func cancel() {
        phase = .idle
    }

    func confirm() {
        guard case .confirming(let request) = phase else { return }
        phase = .running
        Task {
            let report = await mover.run(
                title: request.title,
                items: request.items,
                executable: request.executable,
                mustRemain: request.mustRemain
            )
            phase = .finished(report)
        }
    }

    func closeReport() {
        guard case .finished(let report) = phase else { return }
        phase = .idle
        onFinished(report)
    }
}
