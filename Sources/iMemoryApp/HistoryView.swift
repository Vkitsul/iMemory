import CleanKit
import SwiftUI

struct HistoryView: View {
    let history: [CleanupReport]

    var body: some View {
        if history.isEmpty {
            ContentUnavailableView(
                "No cleanups yet",
                systemImage: "clock",
                description: Text("Every cleanup shows up here, with the items deleted and the space measured.")
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
                                Text("And \(Format.count(rule.removedItems.count - 200)) more items.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Format.dateTime(report.date) + (report.wasScheduled == true ? ", scheduled" : ""))
                                .fontWeight(.medium)
                            Text(report.isTrashOperation
                                ? "In the Trash: \(Format.items(report.removedItemCount)), \(report.rules.first?.title ?? "")"
                                : "Deleted: \(Format.items(report.removedItemCount)), estimate \(Format.estimate(minimum: report.expectedPrivate, maximum: report.expectedAllocated))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(report.isTrashOperation ? "Trash" : report.measuredFreed > 0 ? Format.bytes(report.measuredFreed) : "–")
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}
