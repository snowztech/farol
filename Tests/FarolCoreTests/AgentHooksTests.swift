import Foundation
import Testing
@testable import FarolCore

/// Commands registered for an event, across all of its groups.
private func commands(_ settings: [String: Any], _ event: String) -> [String] {
    let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

@Test func installsIntoEmptySettings() {
    let settings = AgentHooks.claude.install(into: [:])
    #expect(AgentHooks.claude.isInstalled(in: settings))
    #expect(commands(settings, "Notification") == [AgentHooks.claude.command("waiting")])
}

@Test func keepsEverythingElse() {
    let mine: [String: Any] = [
        "model": "opus",
        "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "my-guard.sh"]]]],
                  "Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
    ]
    let settings = AgentHooks.claude.install(into: mine)
    #expect(settings["model"] as? String == "opus")
    #expect(commands(settings, "PreToolUse") == ["my-guard.sh"])
    #expect(commands(settings, "Stop") == ["say done", AgentHooks.claude.command("done")])
}

@Test func installingTwiceChangesNothing() {
    let once = AgentHooks.claude.install(into: [:])
    let twice = AgentHooks.claude.install(into: once)
    #expect(NSDictionary(dictionary: once).isEqual(to: twice))
}

@Test func notInstalledWhenOneHookIsMissing() {
    var settings = AgentHooks.claude.install(into: [:])
    var hooks = settings["hooks"] as! [String: Any]
    hooks["Stop"] = nil
    settings["hooks"] = hooks
    #expect(!AgentHooks.claude.isInstalled(in: settings))
}

@Test func removingLeavesOtherHooks() {
    let mine: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]]
    let settings = AgentHooks.claude.remove(from: AgentHooks.claude.install(into: mine))
    #expect(!AgentHooks.claude.isInstalled(in: settings))
    #expect(commands(settings, "Stop") == ["say done"])
    #expect((settings["hooks"] as? [String: Any])?["Notification"] == nil)
}

@Test func removingEverythingDropsTheHooksKey() {
    let settings = AgentHooks.claude.remove(from: AgentHooks.claude.install(into: ["model": "opus"]))
    #expect(settings["hooks"] == nil)
    #expect(settings["model"] as? String == "opus")
}

@Test func writesWithABackup() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("farol-hooks-\(UUID().uuidString)")
    let url = dir.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"model":"opus"}"#.utf8).write(to: url)

    try AgentHooks.write(AgentHooks.claude.install(into: try AgentHooks.read(url)), to: url)

    #expect(AgentHooks.claude.isInstalled(in: try AgentHooks.read(url)))
    #expect(try AgentHooks.read(url)["model"] as? String == "opus")
    let backup = try String(contentsOf: url.appendingPathExtension("farol-backup"), encoding: .utf8)
    #expect(backup == #"{"model":"opus"}"#)
}

@Test func refusesAFileThatIsNotAnObject() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("farol-hooks-\(UUID().uuidString).json")
    try Data("[1,2]".utf8).write(to: url)
    #expect(throws: (any Error).self) { try AgentHooks.read(url) }
}

/// A busy settings file survives Connect then Disconnect with nothing lost or changed.
@Test func connectThenDisconnectGivesBackTheSameSettings() throws {
    let original = #"""
    {
      "model": "opus",
      "includeCoAuthoredBy": false,
      "cleanupPeriodDays": 30,
      "env": { "DISABLE_TELEMETRY": "1" },
      "permissions": { "allow": ["Bash(git status)", "Read(~/docs/**)"], "deny": ["Bash(rm -rf /)"] },
      "statusLine": { "type": "command", "command": "~/.claude/status.sh" },
      "enabledPlugins": { "caveman@plugins": true },
      "hooks": {
        "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/guard.sh", "timeout": 5 }] }],
        "Stop": [
          { "hooks": [{ "type": "command", "command": "say done" }] },
          { "matcher": "", "hooks": [{ "type": "command", "command": "afplay ~/ding.aiff" }] }
        ],
        "Notification": [{ "hooks": [{ "type": "command", "command": "terminal-notifier -message 'Claude a besoin de toi'" }] }]
      }
    }
    """#
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("farol-hooks-\(UUID().uuidString)")
    let url = dir.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(original.utf8).write(to: url)
    let before = try AgentHooks.read(url) as NSDictionary

    try AgentHooks.write(AgentHooks.claude.install(into: try AgentHooks.read(url)), to: url)
    let connected = try AgentHooks.read(url)
    #expect(AgentHooks.claude.isInstalled(in: connected))
    // Farol's hook comes after the user's own, never in place of them.
    #expect(commands(connected, "Stop") == ["say done", "afplay ~/ding.aiff", AgentHooks.claude.command("done")])
    #expect(commands(connected, "PreToolUse") == ["~/guard.sh"])
    var withoutFarol = AgentHooks.claude.remove(from: connected)
    #expect((withoutFarol as NSDictionary).isEqual(to: before as! [AnyHashable: Any]))

    try AgentHooks.write(AgentHooks.claude.remove(from: connected), to: url)
    withoutFarol = try AgentHooks.read(url)
    #expect((withoutFarol as NSDictionary).isEqual(to: before as! [AnyHashable: Any]))
}

/// Hooks from an older Farol, without the Notification matcher, get replaced instead of doubled.
@Test func connectUpdatesOlderHooks() {
    let old: [String: Any] = ["hooks": [
        "Notification": [["hooks": [["type": "command", "command": AgentHooks.claude.command("waiting")]]]],
        "Stop": [["hooks": [["type": "command", "command": "say done"]]]],
    ]]
    #expect(!AgentHooks.claude.isInstalled(in: old))

    let updated = AgentHooks.claude.install(into: old)
    let groups = (updated["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]] ?? []
    #expect(groups.count == 1)
    #expect(groups.first?["matcher"] as? String == "permission_prompt|elicitation_dialog")
    #expect(commands(updated, "Stop") == ["say done", AgentHooks.claude.command("done")])
    #expect(AgentHooks.claude.isInstalled(in: updated))
}

// MARK: Codex

@Test func codexWaitsOnPermissionRequests() {
    let settings = AgentHooks.codex.install(into: [:])
    #expect(AgentHooks.codex.isInstalled(in: settings))
    #expect(commands(settings, "PermissionRequest") == [AgentHooks.codex.command("waiting")])
    #expect(commands(settings, "Stop") == [AgentHooks.codex.command("done")])
    #expect(commands(settings, "Notification").isEmpty)
}

/// A hooks.json that already runs another tool at session start, like herdr's, keeps it through connect and disconnect.
@Test func codexKeepsOtherHooks() throws {
    let theirs: [String: Any] = ["hooks": [
        "SessionStart": [["hooks": [["type": "command", "command": "bash ~/.codex/herdr-agent-state.sh session", "timeout": 10]]]],
    ]]
    let connected = AgentHooks.codex.install(into: theirs)
    #expect(commands(connected, "SessionStart") == ["bash ~/.codex/herdr-agent-state.sh session", AgentHooks.codex.command("clear")])
    let disconnected = AgentHooks.codex.remove(from: connected) as NSDictionary
    #expect(disconnected.isEqual(to: theirs))
}

@Test func agentsUseTheirOwnFiles() {
    #expect(AgentHooks.claude.file.path.hasSuffix(".claude/settings.json"))
    #expect(AgentHooks.codex.file.path.hasSuffix(".codex/hooks.json"))
}

/// Hooks name their agent, so the sidebar can show which one is in a session.
@Test func hooksNameTheirAgent() {
    #expect(AgentHooks.claude.command("done").hasSuffix("status done --agent claude"))
    #expect(AgentHooks.codex.command("waiting").hasSuffix("status waiting --agent codex"))
}

/// Hooks from before the agent name count as outdated, so Settings offers Update.
@Test func hooksWithoutTheAgentNameNeedAnUpdate() {
    let old: [String: Any] = ["hooks": [
        "Stop": [["hooks": [["type": "command", "command": "[ -z \"$FAROL_CLI\" ] || \"$FAROL_CLI\" status done"]]]],
    ]]
    #expect(!AgentHooks.claude.isInstalled(in: old))
    #expect(AgentHooks.claude.hasAnyFarolHook(in: old))
}
