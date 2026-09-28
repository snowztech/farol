import Foundation
import Testing
@testable import FarolCore

/// Commands registered for an event, across all of its groups.
private func commands(_ settings: [String: Any], _ event: String) -> [String] {
    let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

@Test func installsIntoEmptySettings() {
    let settings = ClaudeHooks.install(into: [:])
    #expect(ClaudeHooks.isInstalled(in: settings))
    #expect(commands(settings, "Notification") == [ClaudeHooks.command("waiting")])
}

@Test func keepsEverythingElse() {
    let mine: [String: Any] = [
        "model": "opus",
        "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "my-guard.sh"]]]],
                  "Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
    ]
    let settings = ClaudeHooks.install(into: mine)
    #expect(settings["model"] as? String == "opus")
    #expect(commands(settings, "PreToolUse") == ["my-guard.sh"])
    #expect(commands(settings, "Stop") == ["say done", ClaudeHooks.command("done")])
}

@Test func installingTwiceChangesNothing() {
    let once = ClaudeHooks.install(into: [:])
    let twice = ClaudeHooks.install(into: once)
    #expect(NSDictionary(dictionary: once).isEqual(to: twice))
}

@Test func notInstalledWhenOneHookIsMissing() {
    var settings = ClaudeHooks.install(into: [:])
    var hooks = settings["hooks"] as! [String: Any]
    hooks["Stop"] = nil
    settings["hooks"] = hooks
    #expect(!ClaudeHooks.isInstalled(in: settings))
}

@Test func removingLeavesOtherHooks() {
    let mine: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]]
    let settings = ClaudeHooks.remove(from: ClaudeHooks.install(into: mine))
    #expect(!ClaudeHooks.isInstalled(in: settings))
    #expect(commands(settings, "Stop") == ["say done"])
    #expect((settings["hooks"] as? [String: Any])?["Notification"] == nil)
}

@Test func removingEverythingDropsTheHooksKey() {
    let settings = ClaudeHooks.remove(from: ClaudeHooks.install(into: ["model": "opus"]))
    #expect(settings["hooks"] == nil)
    #expect(settings["model"] as? String == "opus")
}

@Test func writesWithABackup() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("farol-hooks-\(UUID().uuidString)")
    let url = dir.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"model":"opus"}"#.utf8).write(to: url)

    try ClaudeHooks.write(ClaudeHooks.install(into: try ClaudeHooks.read(url)), to: url)

    #expect(ClaudeHooks.isInstalled(in: try ClaudeHooks.read(url)))
    #expect(try ClaudeHooks.read(url)["model"] as? String == "opus")
    let backup = try String(contentsOf: url.appendingPathExtension("farol-backup"), encoding: .utf8)
    #expect(backup == #"{"model":"opus"}"#)
}

@Test func refusesAFileThatIsNotAnObject() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("farol-hooks-\(UUID().uuidString).json")
    try Data("[1,2]".utf8).write(to: url)
    #expect(throws: (any Error).self) { try ClaudeHooks.read(url) }
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
    let before = try ClaudeHooks.read(url) as NSDictionary

    try ClaudeHooks.write(ClaudeHooks.install(into: try ClaudeHooks.read(url)), to: url)
    let connected = try ClaudeHooks.read(url)
    #expect(ClaudeHooks.isInstalled(in: connected))
    // Farol's hook comes after the user's own, never in place of them.
    #expect(commands(connected, "Stop") == ["say done", "afplay ~/ding.aiff", ClaudeHooks.command("done")])
    #expect(commands(connected, "PreToolUse") == ["~/guard.sh"])
    var withoutFarol = ClaudeHooks.remove(from: connected)
    #expect((withoutFarol as NSDictionary).isEqual(to: before as! [AnyHashable: Any]))

    try ClaudeHooks.write(ClaudeHooks.remove(from: connected), to: url)
    withoutFarol = try ClaudeHooks.read(url)
    #expect((withoutFarol as NSDictionary).isEqual(to: before as! [AnyHashable: Any]))
}

/// Hooks from an older Farol, without the Notification matcher, get replaced instead of doubled.
@Test func connectUpdatesOlderHooks() {
    let old: [String: Any] = ["hooks": [
        "Notification": [["hooks": [["type": "command", "command": ClaudeHooks.command("waiting")]]]],
        "Stop": [["hooks": [["type": "command", "command": "say done"]]]],
    ]]
    #expect(!ClaudeHooks.isInstalled(in: old))

    let updated = ClaudeHooks.install(into: old)
    let groups = (updated["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]] ?? []
    #expect(groups.count == 1)
    #expect(groups.first?["matcher"] as? String == "permission_prompt|elicitation_dialog")
    #expect(commands(updated, "Stop") == ["say done", ClaudeHooks.command("done")])
    #expect(ClaudeHooks.isInstalled(in: updated))
}
