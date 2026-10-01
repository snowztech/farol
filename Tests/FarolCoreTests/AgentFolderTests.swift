import Foundation
import Testing
@testable import FarolCore

/// A home with the given folders, each holding the given files.
private func home(_ folders: [String: [String]]) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("farol-home-\(UUID().uuidString)")
    for (folder, files) in folders {
        let directory = home.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files { try Data().write(to: directory.appendingPathComponent(file)) }
    }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

@Test func findsEveryFolderWithItsConfigFile() throws {
    let h = try home([
        ".claude": ["settings.json"], ".claude-work": ["settings.json"], ".claude-personal": ["settings.json"],
        ".claude-backup": [], ".codex": ["config.toml"], ".codex-work": ["config.toml"], ".codex-old": ["auth.json"],
    ])
    let found = AgentFolder.find(home: h, environment: [:])
    #expect(found.map(\.label) == [
        "Claude Code", "Claude Code (personal)", "Claude Code (work)", "Codex", "Codex (work)",
    ])
}

@Test func theDefaultFolderIsAlwaysThere() throws {
    let found = AgentFolder.find(home: try home([:]), environment: [:])
    #expect(found.map(\.label) == ["Claude Code", "Codex"])
}

@Test func findsTheFoldersTheEnvironmentNames() throws {
    let h = try home([".claude": []])
    let found = AgentFolder.find(home: h, environment: ["CLAUDE_CONFIG_DIR": "/work/acme", "CODEX_HOME": "/work/codex-acme"])
    #expect(found.map(\.label) == ["Claude Code", "Claude Code (acme)", "Codex", "Codex (acme)"])
}

@Test func theEnvironmentFolderIsNotListedTwice() throws {
    let h = try home([".claude": [], ".claude-work": ["settings.json"]])
    let found = AgentFolder.find(home: h, environment: [
        "CLAUDE_CONFIG_DIR": h.appendingPathComponent(".claude-work").path, "CODEX_HOME": "",
    ])
    #expect(found.map(\.label) == ["Claude Code", "Claude Code (work)", "Codex"])
}

@Test func commandSetsTheFolderOnlyOffTheDefault() {
    let home = URL(fileURLWithPath: "/h")
    let work = AgentFolder(kind: .claude, directory: home.appendingPathComponent(".claude-work"))
    let codex = AgentFolder(kind: .codex, directory: home.appendingPathComponent(".codex-work"))
    #expect(AgentFolder(kind: .claude, directory: home.appendingPathComponent(".claude")).command() == "claude")
    #expect(work.command() == "CLAUDE_CONFIG_DIR='/h/.claude-work' claude")
    #expect(work.command(task: "it's done") == #"CLAUDE_CONFIG_DIR='/h/.claude-work' claude 'it'\''s done'"#)
    #expect(codex.command(task: "Fix") == "CODEX_HOME='/h/.codex-work' codex 'Fix'")
}

@Test func theSavedChoiceSurvivesTheOldFormat() {
    let folders = [".claude", ".claude-work", ".codex"].map {
        AgentFolder(kind: $0.hasPrefix(".claude") ? .claude : .codex, directory: URL(fileURLWithPath: "/h/\($0)"))
    }
    #expect(AgentFolder.choice("/h/.claude-work", in: folders)?.label == "Claude Code (work)")
    #expect(AgentFolder.choice("codex", in: folders)?.label == "Codex")
    #expect(AgentFolder.choice("/gone", in: folders)?.label == "Claude Code")
}
