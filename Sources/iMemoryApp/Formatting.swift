import Foundation
import ScanKit
import SwiftUI

enum Format {
    private static let italian = Locale(identifier: "it_IT")

    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file).locale(italian))
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(italian))
    }

    static func items(_ value: Int) -> String {
        "\(count(value)) \(value == 1 ? "voce" : "voci")"
    }

    static func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(italian))
    }

    static func dateTime(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(italian))
    }

    /// How much a cleanup will free. Two figures only when clones make them differ.
    static func spaceRange(minimum: Int64, maximum: Int64) -> String {
        let low = bytes(minimum), high = bytes(maximum)
        if low == high { return "Libera \(high)" }
        return minimum == 0 ? "Libera fino a \(high)" : "Libera fra \(low) e \(high)"
    }

    /// The same estimate, for a report written after the fact.
    static func estimate(minimum: Int64, maximum: Int64) -> String {
        let low = bytes(minimum), high = bytes(maximum)
        if low == high { return high }
        return minimum == 0 ? "fino a \(high)" : "\(low)–\(high)"
    }

    static func seconds(_ duration: Duration) -> String {
        let parts = duration.components
        let value = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return value.formatted(.number.precision(.fractionLength(1)).locale(italian)) + " s"
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
        case .applications: "App"
        case .appData: "Dati delle app"
        case .photos: "Immagini"
        case .iPhoneBackups: "Backup di iPhone"
        case .developer: "Sviluppatore"
        case .caches: "Cache"
        case .userFiles: "I tuoi file"
        case .systemData: "Dati di sistema"
        case .unattributed: "Non attribuito"
        case .otherVolumes: "Volumi di sistema"
        }
    }

    var explanation: String {
        switch self {
        case .applications: "La cartella Applicazioni."
        case .appData: "La Libreria della tua cartella utente, senza cache, backup e strumenti di sviluppo."
        case .photos: "La cartella Immagini, compresa la libreria Foto."
        case .iPhoneBackups: "I backup locali di iPhone e iPad."
        case .developer: "Simulatori e dati di compilazione di Xcode."
        case .caches: "File temporanei che le app possono ricreare."
        case .userFiles: "Documenti, Scrivania, Download e il resto della tua cartella."
        case .systemData: "Cartelle di sistema sul volume dati e altri utenti."
        case .unattributed: "Almeno questo spazio non è attribuito a nessuna cartella: si trova in cartelle non leggibili o nei metadati del disco. Può essere di più, perché i cloni APFS contano più volte nel totale misurato."
        case .otherVolumes: "Sistema, Preboot, Recovery e memoria virtuale. Li gestisce macOS."
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
