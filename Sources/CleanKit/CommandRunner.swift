import Foundation
import RulesKit

public struct CommandOutcome: Sendable, Equatable {
    /// `nil` if the command could not start or ran out of time.
    public let status: Int32?
    public let output: String

    public init(status: Int32?, output: String) {
        self.status = status
        self.output = output
    }
}

/// Runs a fixed program with fixed arguments, without a shell, so nothing in the
/// arguments can be interpreted as anything else.
public enum CommandRunner {
    private static let outputLimit = 256 * 1024

    /// Blocks until the command ends or `timeout` passes.
    @Sendable
    public static func run(executable: String, arguments: [String], timeout: Duration) -> CommandOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return CommandOutcome(status: nil, output: error.localizedDescription)
        }

        // Read while it runs: a full pipe would otherwise block the command forever.
        let reader = OutputReader(handle: pipe.fileHandleForReading, limit: outputLimit)
        reader.start()

        let parts = timeout.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        let timedOut = finished.wait(timeout: .now() + seconds) == .timedOut
        if timedOut {
            process.terminate()
            finished.wait()
        }
        let output = reader.finish()
        return CommandOutcome(status: timedOut ? nil : process.terminationStatus, output: output)
    }
}

private final class OutputReader: @unchecked Sendable {
    private let handle: FileHandle
    private let limit: Int
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()

    init(handle: FileHandle, limit: Int) {
        self.handle = handle
        self.limit = limit
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            while case let chunk = handle.availableData, !chunk.isEmpty {
                if data.count < limit {
                    data.append(chunk.prefix(limit - data.count))
                }
            }
            done.signal()
        }
    }

    /// `data` is written only by the reader, and read only after it signals.
    func finish() -> String {
        // A child of the command may keep the pipe open, so don't wait forever.
        _ = done.wait(timeout: .now() + 2)
        try? handle.close()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Read-only questions asked of developer tools, to learn whether a command has any work
/// to do and how much it would free. Rules with nothing to do don't appear at all.
public enum DeveloperProbes {
    private static let timeout = Duration.seconds(30)

    /// Estimates by rule ID, given what the scan measured. Only rules with work to do.
    public static func commandEstimates(
        catalog: RuleCatalog,
        sizeAtHomePath: (String) -> Int64,
        run: (String, [String], Duration) -> CommandOutcome = CommandRunner.run
    ) -> [String: Int64] {
        var estimates: [String: Int64] = [:]

        for rule in catalog.rules {
            guard let command = rule.command else { continue }
            guard FileManager.default.isExecutableFile(atPath: command.executable) else { continue }

            switch rule.id {
            case "simulators.unavailable":
                let outcome = run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"], timeout)
                let devices = outcome.status == 0 ? unavailableDeviceIDs(fromJSON: outcome.output) : []
                if !devices.isEmpty {
                    estimates[rule.id] = devices
                        .map { sizeAtHomePath("Library/Developer/CoreSimulator/Devices/" + $0) }
                        .reduce(0, +)
                }
            case "simulators.eraseall":
                let size = sizeAtHomePath("Library/Developer/CoreSimulator/Devices")
                if size > 0 {
                    estimates[rule.id] = size
                }
            case "homebrew.oldversions":
                let outcome = run("/opt/homebrew/bin/brew", ["cleanup", "--dry-run", "--prune=all"], timeout)
                guard outcome.status == 0, let total = brewEstimate(fromOutput: outcome.output) else { continue }
                // The cache has its own rule. Only what lies beyond it needs this one.
                let beyondCache = total - sizeAtHomePath("Library/Caches/Homebrew")
                if beyondCache >= 1_000_000 {
                    estimates[rule.id] = beyondCache
                }
            default:
                break
            }
        }
        return estimates
    }

    static func unavailableDeviceIDs(fromJSON text: String) -> [String] {
        struct Listing: Decodable {
            struct Device: Decodable {
                let udid: String
            }

            let devices: [String: [Device]]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: Data(text.utf8)) else { return [] }
        return listing.devices.values.flatMap { $0.map(\.udid) }.sorted()
    }

    /// Reads "would free approximately 454.1MB", which brew prints in decimal units.
    static func brewEstimate(fromOutput text: String) -> Int64? {
        guard let match = text.firstMatch(of: /would free approximately ([0-9.]+)\s*([KMGT]?)B/) else { return nil }
        guard let value = Double(match.1) else { return nil }
        let scale: Double = switch match.2 {
        case "K": 1e3
        case "M": 1e6
        case "G": 1e9
        case "T": 1e12
        default: 1
        }
        return Int64(value * scale)
    }
}
