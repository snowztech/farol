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

@Test func aLogNamesItsAgentAndAccount() {
    let claude = AgentFolder(log: "/h/.claude-work/projects/-h-app/8258e980.jsonl")
    let codex = AgentFolder(log: "/h/.codex/sessions/2026/10/18/rollout-1.jsonl")
    #expect(claude == AgentFolder(kind: .claude, directory: URL(fileURLWithPath: "/h/.claude-work")))
    #expect(codex == AgentFolder(kind: .codex, directory: URL(fileURLWithPath: "/h/.codex")))
    #expect(AgentFolder(log: "/tmp/notes.jsonl") == nil)
    // A config folder inside a folder named like the other agent's logs.
    #expect(AgentFolder(log: "/h/projects/codex/sessions/2026/10/18/rollout-1.jsonl")
        == AgentFolder(kind: .codex, directory: URL(fileURLWithPath: "/h/projects/codex")))
}

@Test func resumePicksUpTheConversationOnItsAccount() {
    let home = URL(fileURLWithPath: "/h")
    #expect(AgentFolder(kind: .claude, directory: home.appendingPathComponent(".claude")).resume("8258e980") == "claude --resume '8258e980'")
    #expect(AgentFolder(kind: .claude, directory: home.appendingPathComponent(".claude-work")).resume("8258e980")
        == "CLAUDE_CONFIG_DIR='/h/.claude-work' claude --resume '8258e980'")
    #expect(AgentFolder(kind: .codex, directory: home.appendingPathComponent(".codex")).resume("019a") == "codex resume '019a'")
}

@Test func findsTheCodexConversationWrittenLastInItsFolder() throws {
    let h = try home([:])
    let codex = AgentFolder(kind: .codex, directory: h.appendingPathComponent(".codex"))
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    let day = codex.directory.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let started = Date().addingTimeInterval(-60)
    func log(_ id: String, in folder: String, written: TimeInterval) throws {
        let file = day.appendingPathComponent("rollout-\(id).jsonl")
        try Data((#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(folder)"}}"# + "\n{}\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: started.addingTimeInterval(written)], ofItemAtPath: file.path)
    }
    try log("before", in: "/work/app", written: -30)
    try log("first", in: "/work/app", written: 10)
    try log("latest", in: "/work/app", written: 20)
    try log("elsewhere", in: "/work/other", written: 30)

    let found = AgentFolder.lastCodexConversation(in: [codex], startedIn: "/work/app", since: started)
    #expect(found?.id == "latest")
    #expect(found.map { URL(fileURLWithPath: $0.log).lastPathComponent } == "rollout-latest.jsonl")
    #expect(AgentFolder.lastCodexConversation(in: [codex], startedIn: "/work/none", since: started) == nil)
}

@Test func theSavedChoiceSurvivesTheOldFormat() {
    let folders = [".claude", ".claude-work", ".codex"].map {
        AgentFolder(kind: $0.hasPrefix(".claude") ? .claude : .codex, directory: URL(fileURLWithPath: "/h/\($0)"))
    }
    #expect(AgentFolder.choice("/h/.claude-work", in: folders)?.label == "Claude Code (work)")
    #expect(AgentFolder.choice("codex", in: folders)?.label == "Codex")
    #expect(AgentFolder.choice("/gone", in: folders)?.label == "Claude Code")
}
