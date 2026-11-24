import Foundation
import ScanKit
import SwiftUI

enum Format {
    /// Follows the region set on the Mac, like any app.
    private static let locale = Locale.autoupdatingCurrent

    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file).locale(locale))
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    static func items(_ value: Int) -> String {
        "\(count(value)) \(value == 1 ? "item" : "items")"
    }

    static func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }

    static func dateTime(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    /// How much a cleanup will free. Two figures only when clones make them differ.
    static func spaceRange(minimum: Int64, maximum: Int64) -> String {
        let low = bytes(minimum), high = bytes(maximum)
        if low == high { return "Frees \(high)" }
        return minimum == 0 ? "Frees up to \(high)" : "Frees \(low) to \(high)"
    }

    /// The same estimate, for a report written after the fact.
    static func estimate(minimum: Int64, maximum: Int64) -> String {
        let low = bytes(minimum), high = bytes(maximum)
        if low == high { return high }
        return minimum == 0 ? "up to \(high)" : "\(low)–\(high)"
    }

    static func seconds(_ duration: Duration) -> String {
        let parts = duration.components
        let value = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return value.formatted(.number.precision(.fractionLength(1)).locale(locale)) + " s"
    }

    /// The path as the user knows it, without the prefix of the data volume.
    static func displayPath(_ path: String) -> String {
        guard path.hasPrefix(AppModel.scanRoot) else { return path }
        let trimmed = String(path.dropFirst(AppModel.scanRoot.count))
        return trimmed.isEmpty ? "/" : trimmed
    }
}

extension StorageBreakdown.Kind {
    var title: String {
        switch self {
        case .applications: "Apps"
        case .appData: "App data"
        case .photos: "Pictures"
        case .iPhoneBackups: "iPhone backups"
        case .developer: "Developer"
        case .caches: "Cache"
        case .userFiles: "Your files"
        case .systemData: "System data"
        case .unattributed: "Unattributed"
        case .otherVolumes: "System volumes"
        }
    }

    var explanation: String {
        switch self {
        case .applications: "The Applications folder."
        case .appData: "The Library in your home folder, without caches, backups, and developer tools."
        case .photos: "The Pictures folder, including the Photos library."
        case .iPhoneBackups: "Local backups of iPhone and iPad."
        case .developer: "Xcode simulators and build data."
        case .caches: "Temporary files that apps can recreate."
        case .userFiles: "Documents, Desktop, Downloads, and the rest of your home folder."
        case .systemData: "System folders on the data volume, and other users."
        case .unattributed: "At least this much space isn't attributed to any folder: it's in unreadable folders or in the disk's metadata. It may be more, because APFS clones count several times in the measured total."
        case .otherVolumes: "System, Preboot, Recovery, and virtual memory. macOS manages them."
        }
    }

    var color: Color {
        switch self {
        case .applications: .indigo
        case .appData: .blue
        case .photos: .pink
        case .iPhoneBackups: .orange
        case .developer: .teal
        case .caches: .green
        case .userFiles: .purple
        case .systemData: .gray
        case .unattributed: .brown
        case .otherVolumes: Color(white: 0.45)
        }
    }
}

extension NodeRow {
    var symbol: String {
        switch kind {
        case .directory: "folder"
        case .file: "doc"
        case .symlink: "arrow.up.right.square"
        case .other: "questionmark.square.dashed"
        }
    }
}
