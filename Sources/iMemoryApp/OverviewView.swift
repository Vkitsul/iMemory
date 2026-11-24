import RulesKit
import ScanKit
import SwiftUI

struct OverviewView: View {
    let session: ScanSession
    let open: (NodeID) -> Void
    let openCleanup: (RuleSection) -> Void

    private var breakdown: StorageBreakdown { session.breakdown }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                StorageBar(breakdown: breakdown)
                if session.unreadableInHome > 0 {
                    permissionNotice
                }
                recommendations
                growth
                categories
                largestFolders
                footer
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Format.bytes(breakdown.free)) liberi")
                .font(.largeTitle.weight(.medium))
            Text("su \(Format.bytes(breakdown.total))")
                .foregroundStyle(.secondary)
        }
    }

    private var permissionNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Format.count(session.unreadableInHome)) cartelle della tua Home non sono leggibili")
                    .fontWeight(.medium)
                Text("Foto, backup e dati di alcune app restano fuori dai totali finché iMemory non ha l'Accesso completo al disco.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Apri Impostazioni") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder
    private var recommendations: some View {
        let top = session.candidates.prefix(3)
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Azioni consigliate")
                    .font(.headline)
                VStack(spacing: 0) {
                    ForEach(top) { candidate in
                        Button {
                            openCleanup(candidate.rule.resolvedSection)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.rule.title)
                                    Text(candidate.rule.explanation)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 16)
                                LevelBadge(level: candidate.rule.level)
                                Text(Format.bytes(candidate.allocated))
                                    .monospacedDigit()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if candidate.id != top.last?.id {
                            Divider()
                        }
                    }
                }
                .background(.background.secondary, in: .rect(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private var growth: some View {
        if let grown = session.growth, !grown.isEmpty, let date = session.previousScanDate {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cosa è cresciuto dal \(Format.dateTime(date))")
                    .font(.headline)
                VStack(spacing: 0) {
                    ForEach(grown) { item in
                        Button {
                            if let node = session.tree.node(atRelativePath: item.path) {
                                open(node)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.up.right")
                                    .foregroundStyle(.secondary)
                                Text("/" + item.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("+\(Format.bytes(item.added))")
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if item.id != grown.last?.id {
                            Divider()
                        }
                    }
                }
                .background(.background.secondary, in: .rect(cornerRadius: 8))
            }
        }
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Spazio occupato")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(breakdown.entries) { entry in
                    CategoryRow(entry: entry, total: breakdown.total, open: open)
                    if entry.id != breakdown.entries.last?.id {
                        Divider()
                    }
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 8))
        }
    }

    private var largestFolders: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cartelle più grandi")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(session.largestFolders, id: \.self) { node in
                    Button { open(node) } label: {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(Format.displayPath(session.tree.path(of: node)))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(Format.bytes(session.tree.sizes(of: node).allocated))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if node != session.largestFolders.last {
                        Divider()
                    }
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 8))
        }
    }

    private var footer: some View {
        Text("\(Format.count(session.tree.count)) voci in \(Format.seconds(session.duration))")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct StorageBar: View {
    let breakdown: StorageBreakdown

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(breakdown.entries) { entry in
                    Rectangle()
                        .fill(entry.kind.color)
                        .frame(width: width(of: entry.bytes, in: geometry.size.width))
                        .help("\(entry.kind.title): \(Format.bytes(entry.bytes))")
                }
                Rectangle()
                    .fill(.quaternary)
                    .help("Libero: \(Format.bytes(breakdown.free))")
            }
        }
        .frame(height: 18)
        .clipShape(.rect(cornerRadius: 5))
        .accessibilityElement()
        .accessibilityLabel("Spazio su disco: \(Format.bytes(breakdown.free)) liberi su \(Format.bytes(breakdown.total))")
    }

    private func width(of bytes: Int64, in available: CGFloat) -> CGFloat {
        guard breakdown.total > 0 else { return 0 }
        return available * CGFloat(bytes) / CGFloat(breakdown.total)
    }
}

private struct CategoryRow: View {
    let entry: StorageBreakdown.Entry
    let total: Int64
    let open: (NodeID) -> Void

    var body: some View {
        if let node = entry.node {
            Button { open(node) } label: {
                content(canOpen: true)
            }
            .buttonStyle(.plain)
        } else {
            content(canOpen: false)
        }
    }

    private func content(canOpen: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(entry.kind.color)
                .frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.kind.title)
                Text(entry.kind.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Text(Format.bytes(entry.bytes))
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .opacity(canOpen ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(.rect)
    }
}

private struct LevelBadge: View {
    let level: RiskLevel

    var body: some View {
        Text(level == .safe ? "Sicuro" : "Da valutare")
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(level == .safe ? .green : .orange)
            .background((level == .safe ? Color.green : Color.orange).opacity(0.15), in: .capsule)
    }
}
