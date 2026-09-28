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
    let mine = "model = \"gpt-5.5\"\n"
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try mine.write(to: config, atomically: true, encoding: .utf8)
    let setup = AgentSetup.codex(config: config, oldHooks: hooks(.codex, at: tempFile("hooks.json")))
    #expect(setup.state() == .disconnected)
    try setup.connect()
    #expect(setup.state() == .connected)
    try setup.disconnect()
    #expect(setup.state() == .disconnected)
    #expect(try CodexNotifications.read(config) == mine)
}

/// Farol 0.6 hooks never reached Farol, so Codex shows as needing an update until connecting removes them.
@Test func codexConnectRemovesOldHooks() throws {
    let old = hooks(.codex, at: tempFile("hooks.json"))
    try old.write(old.install(into: [:]))
    let setup = AgentSetup.codex(config: tempFile("config.toml"), oldHooks: old)
    #expect(setup.state() == .outdated)
    try setup.connect()
    #expect(setup.state() == .connected)
    #expect(!old.hasAnyFarolHook(in: try old.read()))
}

@Test func everyAgentHasItsOwnName() {
    #expect(Set(AgentSetup.all.map(\.name)).count == AgentSetup.all.count)
}
