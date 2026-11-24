import Foundation

/// A record of every cleanup, one JSON object per line. Appending never rewrites earlier
/// entries, and a damaged line costs only that entry.
public struct CleanupHistory: Sendable {
    private let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func append(_ report: CleanupReport) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(report)
        line.append(UInt8(ascii: "\n"))

        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Newest first. Missing file means no history yet.
    public func load() -> [CleanupReport] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(CleanupReport.self, from: Data($0)) }
            .reversed()
    }
}
