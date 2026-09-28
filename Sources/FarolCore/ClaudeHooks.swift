import Foundation

/// Connects Claude Code to Farol by adding hooks that call `farol status` to its settings file.
/// Only hooks whose command mentions $FAROL_CLI are Farol's. Everything else in the file is left alone.
public enum ClaudeHooks {
    /// Claude Code event, the status it maps to, and which occurrences count.
    /// Notification also fires as an idle reminder after a finished turn. Only permission prompts and questions mean waiting.
    public static let events: [(event: String, status: String, matcher: String?)] = [
        ("UserPromptSubmit", "working", nil),
        ("PostToolUse", "working", nil),
        ("Notification", "waiting", "permission_prompt|elicitation_dialog"),
        ("Stop", "done", nil),
        ("SessionEnd", "clear", nil),
    ]

    public static let defaultSettings = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    /// Does nothing outside Farol, where $FAROL_CLI is unset.
    public static func command(_ status: String) -> String {
        "[ -z \"$FAROL_CLI\" ] || \"$FAROL_CLI\" status \(status)"
    }

    /// True when every Farol hook is there in its current form. Older ones count as missing, so Connect updates them.
    public static func isInstalled(in settings: [String: Any]) -> Bool {
        events.allSatisfy { has(command($0.status), matcher: $0.matcher, for: $0.event, in: settings) }
    }

    /// Some Farol hook is there, current or not. With isInstalled false, that means they need an update.
    public static func hasAnyFarolHook(in settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains(where: isFarol)
            }
        }
    }

    /// Replaces Farol's hooks with the current ones and leaves the rest alone. Running it again changes nothing.
    public static func install(into settings: [String: Any]) -> [String: Any] {
        var settings = remove(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, status, matcher) in events {
            var group: [String: Any] = ["hooks": [["type": "command", "command": command(status)]]]
            if let matcher { group["matcher"] = matcher }
            hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [group]
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Removes Farol's hooks, and any group or event they leave empty.
    public static func remove(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, _, _) in events {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let others = entries.filter { !isFarol($0) }
                if others.isEmpty { return nil }
                var group = group
                group["hooks"] = others
                return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    // MARK: File

    public static func read(_ url: URL = defaultSettings) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Farol", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(url.path) is not a JSON object."])
        }
        return object
    }

    /// Writes the settings, keeping the previous file next to it as a backup.
    public static func write(_ settings: [String: Any], to url: URL = defaultSettings) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("farol-backup")
            try? manager.removeItem(at: backup)
            try manager.copyItem(at: url, to: backup)
        }
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    // MARK: Helpers

    private static func has(_ command: String, matcher: String?, for event: String, in settings: [String: Any]) -> Bool {
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.contains { group in
            group["matcher"] as? String == matcher
                && (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String) == command }
        }
    }

    private static func isFarol(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains("FAROL_CLI") == true
    }
}
