import Foundation
import Testing
@testable import FarolCore

/// A home folder of its own, with the files given, by path.
private func home(_ files: [String: String]) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("farol-commands-\(UUID().uuidString)")
    for (path, text) in files {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    return home
}

@Test func claudeListsItsOwnThenYoursTheProjectsAndPluginsTurnedOn() throws {
    let home = try home([
        ".claude/commands/ship.md": "---\ndescription: Push and open a pull request\n---\nDo it.",
        ".claude/commands/git/sync.md": "# Sync\nFetch and rebase on main.",
        ".claude/skills/farol/SKILL.md": "---\nname: farol\ndescription: Farol terminal settings\n---\n",
        ".claude/skills/hidden/SKILL.md": "---\nname: hidden\nuser-invocable: false\n---\n",
        ".claude/settings.json": #"{"enabledPlugins": {"design@market": true, "off@market": false}}"#,
        ".claude/plugins/installed_plugins.json": #"{"plugins": {"design@market": [{"installPath": "PLUGINS/design"}], "off@market": [{"installPath": "PLUGINS/off"}]}}"#,
        "plugins/design/skills/review/SKILL.md": "---\nname: review\ndescription: Review a design\n---\n",
        "plugins/off/skills/nope/SKILL.md": "---\nname: nope\n---\n",
        "shelf/.claude/commands/release.md": "Cut a release.",
    ])
    let installed = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
    let text = try String(contentsOf: installed, encoding: .utf8).replacingOccurrences(of: "PLUGINS", with: home.appendingPathComponent("plugins").path)
    try Data(text.utf8).write(to: installed)

    let log = home.appendingPathComponent(".claude/projects/shelf/abc.jsonl").path
    let commands = AgentCommands.list(log: log, project: home.appendingPathComponent("shelf").path, home: home)
    let names = commands.map(\.name)
    #expect(names.contains("compact"))
    #expect(names.contains("ship"))
    #expect(names.contains("git:sync"))
    #expect(names.contains("farol"))
    #expect(names.contains("release"))
    #expect(names.contains("design:review"))
    #expect(!names.contains("hidden"))
    #expect(!names.contains("off:nope"))
    #expect(names == names.sorted())
    #expect(commands.first { $0.name == "ship" }?.detail == "Push and open a pull request")
    #expect(commands.first { $0.name == "git:sync" }?.detail == "Fetch and rebase on main.")
    #expect(commands.first { $0.name == "model" }?.menu == true)
}

@Test func codexListsItsOwnYourPromptsAndItsSkillsToMention() throws {
    let home = try home([
        ".codex/prompts/standup.md": "---\ndescription: Write my standup\n---\n",
        ".agents/skills/archify/SKILL.md": "---\nname: archify\ndescription: Draw the architecture\n---\n",
        ".codex/skills/farol/SKILL.md": "---\nname: farol\n---\n",
        ".codex/skills/.system/plan/SKILL.md": "---\nname: plan\n---\n",
        ".codex/skills/quiet/SKILL.md": "---\nname: quiet\n---\n",
        "shelf/.agents/skills/release/SKILL.md": "---\nname: release\n---\n",
    ])
    let quiet = home.appendingPathComponent(".codex/skills/quiet/SKILL.md").path
    try Data("model = \"gpt-5\"\n\n[[skills.config]]\npath = \"\(quiet)\"\nenabled = false\n".utf8)
        .write(to: home.appendingPathComponent(".codex/config.toml"))
    let log = home.appendingPathComponent(".codex/sessions/2026/10/16/rollout.jsonl").path
    let commands = AgentCommands.list(log: log, project: home.appendingPathComponent("shelf").path, home: home)
    let slash = commands.filter { !$0.mention }.map(\.name), mentions = commands.filter(\.mention).map(\.name)
    #expect(slash.contains("prompts:standup"))
    #expect(slash.contains("approvals"))
    #expect(!slash.contains("plugin"))
    #expect(Set(mentions) == ["archify", "farol", "plan", "release"])
}

@Test func withoutALogItIsClaudeCodeInItsDefaultFolder() throws {
    let home = try home([".claude/skills/farol/SKILL.md": "---\nname: farol\n---\n"])
    let names = AgentCommands.list(log: nil, project: nil, home: home).map(\.name)
    #expect(names.contains("farol"))
    #expect(names.contains("clear"))
}
