import Foundation
import RulesKit

/// What the user chose to automate. Everything that acts on the disk starts off.
public struct AutomationSettings: Codable, Equatable, Sendable {
    public enum Interval: String, Codable, CaseIterable, Sendable {
        case weekly, monthly

        var seconds: TimeInterval {
            switch self {
            case .weekly: 7 * 86_400
            case .monthly: 30 * 86_400
            }
        }
    }

    public var showsMenuBarIcon = true
    public var warnsOnLowSpace = false
    public var lowSpaceThresholdGB = 20
    public var cleansOnSchedule = false
    public var interval = Interval.weekly
    /// When scheduled cleanups were turned on. Saved, because the app may not stay open for
    /// a whole interval, and counting from each launch would mean it never comes due.
    public var scheduleEnabledAt: Date?
    public var lastScheduledCleanup: Date?

    public init() {}

    /// Turns scheduled cleanups on or off. Turning them on starts a full interval.
    public mutating func setCleansOnSchedule(_ isOn: Bool, now: Date = .now) {
        guard isOn != cleansOnSchedule else { return }
        cleansOnSchedule = isOn
        scheduleEnabledAt = isOn ? now : nil
        if isOn {
            lastScheduledCleanup = nil
        }
    }

    /// A missing or damaged file gives the defaults, so it can never turn cleanup on.
    public static func load(from file: URL) -> AutomationSettings {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file),
              let settings = try? decoder.decode(AutomationSettings.self, from: data)
        else { return AutomationSettings() }
        return settings
    }

    public func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}

/// Decides what may run without anyone looking at it.
public enum ScheduledCleanup {
    /// Whether a scheduled cleanup should run now. The first one waits a full interval from
    /// being turned on, so turning the option on doesn't delete anything on the spot.
    public static func isDue(settings: AutomationSettings, now: Date) -> Bool {
        guard settings.cleansOnSchedule else { return false }
        guard let reference = settings.lastScheduledCleanup ?? settings.scheduleEnabledAt else { return false }
        return now.timeIntervalSince(reference) >= settings.interval.seconds
    }

    /// Only rules marked safe that remove files themselves. A command's effect is up to its
    /// tool, so it always waits for someone to confirm it, however safe it is rated.
    public static func eligible(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        candidates.filter { $0.rule.level == .safe && $0.rule.command == nil }
    }
}
