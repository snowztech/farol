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
