import Foundation

public enum RiskLevel: String, Codable, Sendable {
    /// Can be recreated at no cost. Selected by default.
    case safe
    /// Can be recreated, but with a cost the user should weigh. Never selected by default.
    case review
}

public enum RuleSection: String, Codable, Sendable {
    case general, developer
}

/// A developer tool's own way of freeing space, for when deleting its files directly
/// would leave the tool in a bad state.
public struct CleanupCommand: Codable, Sendable, Equatable {
    /// Absolute, so that nothing on `PATH` can stand in for the real tool.
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// As shown to the user before running it.
    public var displayText: String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
    }
}

/// One kind of space the app knows how to reclaim.
///
/// Rules are data, so they can be reviewed apart from the engine. A rule can only ever
/// name folders that `RootPolicy` accepts, whatever the catalog says.
public struct CleaningRule: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let explanation: String
    public let level: RiskLevel
    /// Which screen shows the rule. Missing means general.
    public let section: RuleSection?
    /// Folders whose contents the rule removes, written as `~/...`. The folders stay.
    /// For a rule with a `command`, the folders the command is about, only to show them.
    public let roots: [String]
    /// Executables that use these files. The rule can't run while one is open.
    public let ownerProcesses: [String]
    /// When set, only files untouched for this long are removed, not whole folders.
    public let minimumAgeDays: Int?
    /// When set, the rule runs this instead of removing anything itself.
    public let command: CleanupCommand?

    public init(
        id: String,
        title: String,
        explanation: String,
        level: RiskLevel,
        section: RuleSection? = nil,
        roots: [String],
        ownerProcesses: [String] = [],
        minimumAgeDays: Int? = nil,
        command: CleanupCommand? = nil
    ) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.level = level
        self.section = section
        self.roots = roots
        self.ownerProcesses = ownerProcesses
        self.minimumAgeDays = minimumAgeDays
        self.command = command
    }

    public var resolvedSection: RuleSection { section ?? .general }
}

public enum RuleError: Error, Equatable {
    case rootNotInHome(rule: String, root: String)
    case rootHasUnsafeComponent(rule: String, root: String)
    case rootNotAllowed(rule: String, root: String)
    case noRoots(rule: String)
    case duplicateID(String)
    case invalidAge(rule: String)
    case commandNotAllowed(rule: String)
    case commandWithAge(rule: String)
}

/// Decides which folders a rule may touch. This is an allowlist in code, on purpose:
/// a mistake in the catalog can at worst point at another cache, never at user data.
public enum RootPolicy {
    /// A root may be something inside one of these, never the folder itself.
    private static let allowedParents = ["Library/Caches", ".npm"]
    /// A root may be exactly one of these.
    private static let allowedExact = [
        "Library/Logs",
        "Library/Developer/Xcode/DerivedData",
        "Library/Developer/Xcode/iOS DeviceSupport",
    ]
    /// Only commands may act on these, because the tool knows what is safe inside them.
    private static let commandOnly = ["Library/Developer/CoreSimulator/Devices"]

    /// Checks a root written as `~/...` and returns its path relative to the home.
    /// - Parameter forCommand: The rule only displays this folder, a command does the work.
    public static func validatedRelativePath(of root: String, rule: String, forCommand: Bool = false) throws -> String {
        guard root.hasPrefix("~/") else {
            throw RuleError.rootNotInHome(rule: rule, root: root)
        }
        let relative = String(root.dropFirst(2))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RuleError.rootHasUnsafeComponent(rule: rule, root: root)
        }
        let isAllowed = allowedExact.contains(relative)
            || allowedParents.contains { relative.hasPrefix($0 + "/") }
            || (forCommand && commandOnly.contains(relative))
        guard isAllowed else {
            throw RuleError.rootNotAllowed(rule: rule, root: root)
        }
        return relative
    }
}

/// The complete list of commands the app may run, exactly as written. Like `RootPolicy`,
/// this is in code so that the catalog can't ask for anything else.
public enum CommandPolicy {
    private static let allowed = [
        CleanupCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"]),
        CleanupCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "erase", "all"]),
        CleanupCommand(executable: "/opt/homebrew/bin/brew", arguments: ["cleanup", "--prune=all"]),
    ]

    public static func isAllowed(_ command: CleanupCommand) -> Bool {
        allowed.contains(command)
    }
}

extension CleaningRule {
    public func validate() throws {
        guard !roots.isEmpty else { throw RuleError.noRoots(rule: id) }
        for root in roots {
            _ = try RootPolicy.validatedRelativePath(of: root, rule: id, forCommand: command != nil)
        }
        if let command {
            guard CommandPolicy.isAllowed(command) else { throw RuleError.commandNotAllowed(rule: id) }
            guard minimumAgeDays == nil else { throw RuleError.commandWithAge(rule: id) }
        }
        if let minimumAgeDays, minimumAgeDays < 1 {
            throw RuleError.invalidAge(rule: id)
        }
    }
}

public struct RuleCatalog: Sendable {
    public let rules: [CleaningRule]

    private struct File: Decodable {
        let rules: [CleaningRule]
    }

    /// Fails if any rule is invalid, instead of quietly dropping it.
    public init(rules: [CleaningRule]) throws {
        var seen = Set<String>()
        for rule in rules {
            guard seen.insert(rule.id).inserted else { throw RuleError.duplicateID(rule.id) }
            try rule.validate()
        }
        self.rules = rules
    }

    public init(json: Data) throws {
        try self.init(rules: JSONDecoder().decode(File.self, from: json).rules)
    }

    /// The catalog compiled into the app from `catalog.json`.
    public static func builtIn() throws -> RuleCatalog {
        try RuleCatalog(json: Data(PackageResources.catalog_json))
    }
}
