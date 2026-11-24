import CleanKit
import SwiftUI

struct HistoryView: View {
    let history: [CleanupReport]

    var body: some View {
        if history.isEmpty {
            ContentUnavailableView(
                "Nessuna pulizia",
                systemImage: "clock",
                description: Text("Qui compare ogni pulizia, con le voci eliminate e lo spazio misurato.")
            )
        } else {
            List(history) { report in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ReportDetails(report: report)
                        ForEach(report.rules) { rule in
                            ForEach(rule.removedItems.prefix(200), id: \.self) { path in
                                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if rule.removedItems.count > 200 {
                                Text("E altre \(Format.count(rule.removedItems.count - 200)) voci.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Format.dateTime(report.date) + (report.wasScheduled == true ? ", programmata" : ""))
                                .fontWeight(.medium)
                            Text(report.isTrashOperation
                                ? "Nel Cestino: \(Format.items(report.removedItemCount)), \(report.rules.first?.title ?? "")"
                                : "Eliminate: \(Format.items(report.removedItemCount)), stima \(Format.estimate(minimum: report.expectedPrivate, maximum: report.expectedAllocated))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(report.isTrashOperation ? "Cestino" : report.measuredFreed > 0 ? Format.bytes(report.measuredFreed) : "–")
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}
