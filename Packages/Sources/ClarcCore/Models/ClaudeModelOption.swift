import Foundation

/// One user-selectable Claude Code model entry.
///
/// `argument` is the value passed to `claude --model`; `actualModelId` and
/// `displayName` describe the provider model configured by tools such as
/// CCSwitch. Keeping these separate prevents compatibility aliases from
/// leaking into the UI.
public struct ClaudeModelOption: Identifiable, Sendable, Equatable {
    public var id: String { argument }
    public let argument: String
    public let actualModelId: String
    public let displayName: String
    public let description: String
    public let isDefault: Bool

    public init(
        argument: String,
        actualModelId: String,
        displayName: String,
        description: String = "",
        isDefault: Bool = false
    ) {
        self.argument = argument
        self.actualModelId = actualModelId
        self.displayName = displayName
        self.description = description
        self.isDefault = isDefault
    }
}

public struct ClaudeModelCatalogSnapshot: Sendable, Equatable {
    public let options: [ClaudeModelOption]
    public let defaultArgument: String

    public init(options: [ClaudeModelOption], defaultArgument: String) {
        self.options = options
        self.defaultArgument = defaultArgument
    }
}

public enum ClaudeModelCatalog {
    private static let aliases = ["fable", "opus", "sonnet", "haiku"]

    /// Parse Claude Code's settings file without requiring every `env` value
    /// to have the same JSON type.
    public static func load(from url: URL) -> ClaudeModelCatalogSnapshot {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fallback
        }

        let env = root["env"] as? [String: Any] ?? [:]
        func string(_ value: Any?) -> String? {
            guard let raw = value as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let configuredDefault = string(root["model"])
            ?? string(env["ANTHROPIC_MODEL"])
            ?? "default"

        var options: [ClaudeModelOption] = []
        for alias in aliases {
            let prefix = "ANTHROPIC_DEFAULT_\(alias.uppercased())_MODEL"
            guard let actual = string(env[prefix]) else { continue }
            options.append(ClaudeModelOption(
                argument: alias,
                actualModelId: actual,
                displayName: string(env["\(prefix)_NAME"]) ?? actual,
                description: string(env["\(prefix)_DESCRIPTION"]) ?? "",
                isDefault: false
            ))
        }

        if let custom = string(env["ANTHROPIC_CUSTOM_MODEL_OPTION"]) {
            options.append(ClaudeModelOption(
                argument: custom,
                actualModelId: custom,
                displayName: string(env["ANTHROPIC_CUSTOM_MODEL_OPTION_NAME"]) ?? custom,
                description: string(env["ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION"]) ?? "",
                isDefault: false
            ))
        }

        var deduplicated: [ClaudeModelOption] = []
        for option in options {
            if let index = deduplicated.firstIndex(where: {
                $0.actualModelId.caseInsensitiveCompare(option.actualModelId) == .orderedSame
            }) {
                if option.argument.caseInsensitiveCompare(configuredDefault) == .orderedSame {
                    deduplicated[index] = option
                }
            } else {
                deduplicated.append(option)
            }
        }
        options = deduplicated

        if options.isEmpty { return fallback }

        let defaultArgument = options.first(where: {
            $0.argument.caseInsensitiveCompare(configuredDefault) == .orderedSame
                || $0.actualModelId.caseInsensitiveCompare(configuredDefault) == .orderedSame
        })?.argument ?? configuredDefault

        options = options.map { option in
            ClaudeModelOption(
                argument: option.argument,
                actualModelId: option.actualModelId,
                displayName: option.displayName,
                description: option.description,
                isDefault: option.argument == defaultArgument
            )
        }

        if !options.contains(where: { $0.argument == defaultArgument }) {
            options.insert(ClaudeModelOption(
                argument: defaultArgument,
                actualModelId: configuredDefault,
                displayName: configuredDefault,
                isDefault: true
            ), at: 0)
        }

        // Put the configured default first, while preserving the stable slot
        // order for the remaining entries.
        if let defaultIndex = options.firstIndex(where: { $0.isDefault }), defaultIndex != 0 {
            let defaultOption = options.remove(at: defaultIndex)
            options.insert(defaultOption, at: 0)
        }
        return ClaudeModelCatalogSnapshot(options: options, defaultArgument: defaultArgument)
    }

    public static let fallback = ClaudeModelCatalogSnapshot(
        options: [
            ClaudeModelOption(argument: "default", actualModelId: "default", displayName: "Default"),
            ClaudeModelOption(argument: "best", actualModelId: "best", displayName: "Best"),
            ClaudeModelOption(argument: "fable", actualModelId: "fable", displayName: "Fable"),
            ClaudeModelOption(argument: "opus", actualModelId: "opus", displayName: "Opus", isDefault: true),
            ClaudeModelOption(argument: "opus[1m]", actualModelId: "opus[1m]", displayName: "Opus 1M"),
            ClaudeModelOption(argument: "opusplan", actualModelId: "opusplan", displayName: "Opus Plan"),
            ClaudeModelOption(argument: "sonnet", actualModelId: "sonnet", displayName: "Sonnet"),
            ClaudeModelOption(argument: "sonnet[1m]", actualModelId: "sonnet[1m]", displayName: "Sonnet 1M"),
            ClaudeModelOption(argument: "haiku", actualModelId: "haiku", displayName: "Haiku"),
        ],
        defaultArgument: "opus"
    )
}
