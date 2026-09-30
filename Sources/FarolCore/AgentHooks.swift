import Foundation

/// Connects a coding agent to Farol by adding hooks that call `farol status` to the agent's hooks file.
/// Claude Code and Codex use the same JSON shape for hooks, so one implementation serves both.
/// Only hooks whose command mentions $FAROL_CLI are Farol's. Everything else in the file is left alone.
public struct AgentHooks {
    /// An agent event, the status it maps to, and which occurrences count.
    public struct Event {
        public let name: String
        public let status: String
        public let matcher: String?
    }

    public let name: String
    /// The file the agent reads its hooks from.
    public let file: URL
    public let events: [Event]
    /// The agent asks before running hooks it hasn't seen, so the first start after connecting shows a prompt.
    public var asksToApproveHooks = false

    /// Notification also fires as an idle reminder after a finished turn. Only permission prompts and questions mean waiting.
    public static let claude = AgentHooks(name: "Claude Code", file: home(".claude/settings.json"), events: [
        Event(name: "UserPromptSubmit", status: "working", matcher: nil),
        Event(name: "PostToolUse", status: "working", matcher: nil),
        Event(name: "Notification", status: "waiting", matcher: "permission_prompt|elicitation_dialog"),
        Event(name: "Stop", status: "done", matcher: nil),
        Event(name: "SessionEnd", status: "clear", matcher: nil),
        // A background agent keeps working after the main agent's Stop, so the pane stays working until it ends.
        Event(name: "SubagentStart", status: "subagent-start", matcher: nil),
        Event(name: "SubagentStop", status: "subagent-stop", matcher: nil),
    ])

    /// Codex 0.159.2 and later pass Farol's pane environment to lifecycle hooks.
    public static let codex = AgentHooks(name: "Codex", file: home(".codex/hooks.json"), events: [
        // Compaction also starts a session event in the middle of a turn, so it must not clear the dot.
        Event(name: "SessionStart", status: "clear", matcher: "startup|resume|clear"),
        Event(name: "UserPromptSubmit", status: "working", matcher: nil),
        Event(name: "PostToolUse", status: "working", matcher: nil),
        Event(name: "PermissionRequest", status: "waiting", matcher: nil),
        Event(name: "PreToolUse", status: "waiting", matcher: "^request_user_input$"),
        Event(name: "Stop", status: "done", matcher: nil),
        Event(name: "Interrupt", status: "clear", matcher: nil),
        Event(name: "SessionEnd", status: "clear", matcher: nil),
        Event(name: "SubagentStart", status: "subagent-start", matcher: nil),
        Event(name: "SubagentStop", status: "subagent-stop", matcher: nil),
    ], asksToApproveHooks: true)

    private static func home(_ path: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
    }

    /// Does nothing outside Farol, where $FAROL_CLI is unset.
    public static func command(_ status: String) -> String {
        "[ -z \"$FAROL_CLI\" ] || \"$FAROL_CLI\" status \(status)"
    }

    /// True when every Farol hook is there in its current form. Older ones count as missing, so Connect updates them.
    public func isInstalled(in settings: [String: Any]) -> Bool {
        events.allSatisfy { Self.has(Self.command($0.status), matcher: $0.matcher, for: $0.name, in: settings) }
    }

    /// Some Farol hook is there, current or not. With isInstalled false, that means they need an update.
    public func hasAnyFarolHook(in settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains(where: Self.isFarol)
            }
        }
    }

    /// Replaces Farol's hooks with the current ones and leaves the rest alone. Running it again changes nothing.
    public func install(into settings: [String: Any]) -> [String: Any] {
        var settings = remove(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var group: [String: Any] = ["hooks": [["type": "command", "command": Self.command(event.status)]]]
            if let matcher = event.matcher { group["matcher"] = matcher }
            hooks[event.name] = (hooks[event.name] as? [[String: Any]] ?? []) + [group]
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Removes Farol's hooks, and any group or event they leave empty.
    /// Every event, not only the current ones, so hooks an older Farol put on other events go too.
    public func remove(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for event in hooks.keys {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let others = entries.filter { !Self.isFarol($0) }
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

    public func read() throws -> [String: Any] { try Self.read(file) }

    public func write(_ settings: [String: Any]) throws { try Self.write(settings, to: file) }

    public static func read(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Farol", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(url.path) is not a JSON object."])
        }
        return object
    }

    /// Writes the settings, keeping the previous file next to it as a backup.
    public static func write(_ settings: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try replace(url, with: data + Data("\n".utf8))
    }

    /// Writes the file atomically, keeping the previous one next to it as a backup.
    static func replace(_ url: URL, with data: Data) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("farol-backup")
            try? manager.removeItem(at: backup)
            try manager.copyItem(at: url, to: backup)
        }
        try data.write(to: url, options: .atomic)
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
