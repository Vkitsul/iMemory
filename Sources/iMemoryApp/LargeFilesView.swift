import AppKit
import AppsKit
import SwiftUI

private enum FileFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case installers = "Installers"
    case archives = "Archives"
    case videos = "Videos"
    case old = "Untouched for 6 months"

    var id: Self { self }

    func matches(_ file: LargeFile) -> Bool {
        switch self {
        case .all: true
        case .installers: file.category == .installer
        case .archives: file.category == .archive
        case .videos: file.category == .video
        case .old: file.modified < Calendar.current.date(byAdding: .month, value: -6, to: .now) ?? .distantPast
        }
    }
}

struct LargeFilesView: View {
    let files: [LargeFile]
    @Bindable var trash: TrashModel

    @State private var filter = FileFilter.all
    @State private var chosen = Set<String>()

    private var visibleFiles: [LargeFile] {
        files.filter(filter.matches)
    }

    /// Chosen files stay chosen when a filter hides them, so the action counts them too.
    private var chosenFiles: [LargeFile] {
        files.filter { chosen.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $filter) {
                ForEach(FileFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()

            if visibleFiles.isEmpty {
                ContentUnavailableView(
                    "No files over 100 MB",
                    systemImage: "doc",
                    description: Text("Outside the Library and hidden folders, your home folder has no files of this kind this large.")
                )
            } else {
                List(visibleFiles) { file in
                    FileRow(file: file, isChosen: Binding(
                        get: { chosen.contains(file.id) },
                        set: { isOn in
                            if isOn {
                                chosen.insert(file.id)
                            } else {
                                chosen.remove(file.id)
                            }
                        }
                    ))
                }
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    if chosenFiles.isEmpty {
                        Text("No files selected")
                    } else {
                        Text(Format.bytes(chosenFiles.map(\.allocated).reduce(0, +)))
                            .fontWeight(.medium)
                        Text(Format.items(chosenFiles.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Move to Trash…") {
                    trash.prepareFiles(chosenFiles)
                }
                .controlSize(.large)
                .disabled(chosenFiles.isEmpty)
            }
            .padding(12)
        }
        .sheet(isPresented: Binding(get: { trash.isPresentingSheet }, set: { _ in })) {
            TrashSheet(trash: trash, app: nil)
                .interactiveDismissDisabled()
        }
    }
}

private struct FileRow: View {
    let file: LargeFile
    @Binding var isChosen: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Select \(URL(fileURLWithPath: file.path).lastPathComponent)", isOn: $isChosen)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: file.path).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(URL(fileURLWithPath: file.path).deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(Format.date(file.modified))
                .foregroundStyle(.secondary)
            Text(Format.bytes(file.allocated))
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            }
        }
    }
}
