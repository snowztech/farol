import Foundation
import Testing
@testable import FarolCore

private func tempFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("farol-setup-\(UUID().uuidString)").appendingPathComponent(name)
}

private func hooks(_ agent: AgentHooks, at url: URL) -> AgentHooks {
    AgentHooks(name: agent.name, file: url, events: agent.events)
}

@Test func claudeGoesOnAndOff() throws {
    let setup = AgentSetup.claude(hooks: hooks(.claude, at: tempFile("settings.json")))
    #expect(setup.state() == .off)
    try setup.enable()
    #expect(setup.state() == .on)
    try setup.disable()
    #expect(setup.state() == .off)
}

@Test func claudeNeedsUpdateWithOldHooks() throws {
    let old = hooks(.claude, at: tempFile("settings.json"))
    try old.write(["hooks": ["Stop": [["hooks": [["type": "command", "command": "\"$FAROL_CLI\" status done"]]]]]])
    let setup = AgentSetup.claude(hooks: old)
    #expect(setup.state() == .outdated)
    try setup.enable()
    #expect(setup.state() == .on)
}

@Test func codexGoesOnAndOffLeavingTheFileAsItWas() throws {
    let config = tempFile("config.toml")
    let mine = "model = \"gpt-5.5\"\n"
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try mine.write(to: config, atomically: true, encoding: .utf8)
    let setup = AgentSetup.codex(config: config, oldHooks: hooks(.codex, at: tempFile("hooks.json")))
    #expect(setup.state() == .off)
    try setup.enable()
    #expect(setup.state() == .on)
    try setup.disable()
    #expect(setup.state() == .off)
    #expect(try CodexNotifications.read(config) == mine)
}

/// Farol 0.6 hooks never reached Farol, so Codex shows as needing an update until Enable removes them.
@Test func codexEnableRemovesOldHooks() throws {
    let old = hooks(.codex, at: tempFile("hooks.json"))
    try old.write(old.install(into: [:]))
    let setup = AgentSetup.codex(config: tempFile("config.toml"), oldHooks: old)
    #expect(setup.state() == .outdated)
    try setup.enable()
    #expect(setup.state() == .on)
    #expect(!old.hasAnyFarolHook(in: try old.read()))
}

@Test func everyAgentHasItsOwnName() {
    #expect(Set(AgentSetup.all.map(\.name)).count == AgentSetup.all.count)
}
