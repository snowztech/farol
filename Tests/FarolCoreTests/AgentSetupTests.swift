import Foundation
import Testing
@testable import FarolCore

private func tempFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("farol-setup-\(UUID().uuidString)").appendingPathComponent(name)
}

private func hooks(_ agent: AgentHooks, at url: URL) -> AgentHooks {
    AgentHooks(name: agent.name, file: url, events: agent.events)
}

@Test func claudeConnectsAndDisconnects() throws {
    let setup = AgentSetup.claude(hooks: hooks(.claude, at: tempFile("settings.json")))
    #expect(setup.state() == .disconnected)
    try setup.connect()
    #expect(setup.state() == .connected)
    try setup.disconnect()
    #expect(setup.state() == .disconnected)
}

@Test(arguments: [AgentFolder.Kind.claude, .codex])
func connectAddsTheSkillAndDisconnectRemovesIt(kind: AgentFolder.Kind) throws {
    let settings = tempFile("hooks.json")
    let skill = AgentSkill(nextTo: settings)
    let setup = kind == .claude
        ? AgentSetup.claude(hooks: hooks(.claude, at: settings))
        : AgentSetup.codex(config: tempFile("config.toml"), hooks: hooks(.codex, at: settings))
    try setup.connect()
    #expect(skill.isCurrent)
    try "from an older Farol".write(to: skill.file, atomically: true, encoding: .utf8)
    #expect(setup.state() == .outdated)
    try setup.connect()
    #expect(setup.state() == .connected)
    try setup.disconnect()
    #expect(!FileManager.default.fileExists(atPath: skill.file.deletingLastPathComponent().path))
}

@Test func claudeNeedsUpdateWithOldHooks() throws {
    let old = hooks(.claude, at: tempFile("settings.json"))
    try old.write(["hooks": ["Stop": [["hooks": [["type": "command", "command": "\"$FAROL_CLI\" status done"]]]]]])
    let setup = AgentSetup.claude(hooks: old)
    #expect(setup.state() == .outdated)
    try setup.connect()
    #expect(setup.state() == .connected)
}

@Test func codexConnectsAndDisconnectsLeavingTheFileAsItWas() throws {
    let config = tempFile("config.toml")
    let codexHooks = hooks(.codex, at: tempFile("hooks.json"))
    let mine = "model = \"gpt-5.5\"\n"
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try mine.write(to: config, atomically: true, encoding: .utf8)
    let setup = AgentSetup.codex(config: config, hooks: codexHooks)
    #expect(setup.state() == .disconnected)
    try setup.connect()
    #expect(setup.state() == .connected)
    #expect(codexHooks.isInstalled(in: try codexHooks.read()))
    try setup.disconnect()
    #expect(setup.state() == .disconnected)
    #expect(!codexHooks.hasAnyFarolHook(in: try codexHooks.read()))
    #expect(try CodexNotifications.read(config) == mine)
}

@Test func codexConnectReplacesTerminalNotificationsWithHooks() throws {
    let config = tempFile("config.toml")
    let codexHooks = hooks(.codex, at: tempFile("hooks.json"))
    let mine = "model = \"gpt-5.5\"\n"
    try CodexNotifications.write(CodexNotifications.enable(in: mine), to: config)
    let setup = AgentSetup.codex(config: config, hooks: codexHooks)
    #expect(setup.state() == .outdated)
    try setup.connect()
    #expect(setup.state() == .connected)
    #expect(codexHooks.isInstalled(in: try codexHooks.read()))
    #expect(try CodexNotifications.read(config) == mine)
}

@Test func everyFolderHasItsOwnSetup() {
    let folders = ["claude", "claude-work", "codex", "codex-work"].map {
        AgentFolder(kind: $0.hasPrefix("claude") ? .claude : .codex, directory: URL(fileURLWithPath: "/h/.\($0)"))
    }
    let setups = AgentSetup.all(folders: folders)
    #expect(setups.map(\.name) == ["Claude Code", "Claude Code (work)", "Codex", "Codex (work)"])
    #expect(Set(setups.map(\.id)).count == setups.count)
    #expect(setups[1].file.path == "/h/.claude-work/settings.json")
    #expect(setups[3].file.path == "/h/.codex-work/hooks.json")
}
