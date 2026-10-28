import Foundation
import Testing
@testable import FarolCore

private func addScript(_ name: String, text: String, to repo: String, executable: Bool = true) throws {
    try FileManager.default.createDirectory(atPath: repo + "/.farol", withIntermediateDirectories: true)
    let path = repo + "/.farol/\(name)"
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
    try Git.run(["add", ".farol/\(name)"], in: repo)
    try Git.run(["-c", "user.name=Farol", "-c", "user.email=farol@example.com", "commit", "--quiet", "-m", "add \(name)"], in: repo)
}

@Test func skipsSetupWhenProjectHasNone() throws {
    let box = try Sandbox()
    let path = try box.worktrees.create(branch: "plain", from: box.repo)
    #expect(WorktreeScripts.starting("codex", in: path) == "codex")
}

@Test func runsSetupBeforeAgentInNewWorktree() throws {
    let box = try Sandbox()
    let marker = URL(fileURLWithPath: box.repo).deletingLastPathComponent().appendingPathComponent("order").path
    try addScript("setup", text: "#!/bin/sh\nprintf 'setup\\n' >> \(NewTask.shellQuoted(marker))\n", to: box.repo)
    let path = try box.worktrees.create(branch: "setup", from: box.repo)
    let command = WorktreeScripts.starting("printf 'agent\\n' >> \(NewTask.shellQuoted(marker))", in: path)

    try Git.run("/bin/sh", ["-c", command!], in: path)

    #expect(try String(contentsOfFile: marker, encoding: .utf8) == "setup\nagent\n")
}

@Test func failedSetupKeepsAgentStopped() throws {
    let box = try Sandbox()
    let marker = URL(fileURLWithPath: box.repo).deletingLastPathComponent().appendingPathComponent("agent").path
    try addScript("setup", text: "#!/bin/sh\nexit 7\n", to: box.repo)
    let path = try box.worktrees.create(branch: "failed", from: box.repo)
    let command = WorktreeScripts.starting("touch \(NewTask.shellQuoted(marker))", in: path)

    let output = try Git.run("/bin/sh", ["-c", command!], in: path)

    #expect(output.contains("Setup failed"))
    #expect(!FileManager.default.fileExists(atPath: marker))
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test func setupMustBeExecutable() throws {
    let box = try Sandbox()
    let marker = URL(fileURLWithPath: box.repo).deletingLastPathComponent().appendingPathComponent("agent").path
    try addScript("setup", text: "#!/bin/sh\nexit 0\n", to: box.repo, executable: false)
    let path = try box.worktrees.create(branch: "not-executable", from: box.repo)
    let command = WorktreeScripts.starting("touch \(NewTask.shellQuoted(marker))", in: path)

    let output = try Git.run("/bin/sh", ["-c", command!], in: path)

    #expect(output.contains("Setup failed"))
    #expect(!FileManager.default.fileExists(atPath: marker))
}

@Test func setsUpEveryRepoBeforeOneAgentStarts() throws {
    let space = try Workspace()
    let marker = URL(fileURLWithPath: space.parent).deletingLastPathComponent().appendingPathComponent("order").path
    for repo in space.repos {
        let name = URL(fileURLWithPath: repo).lastPathComponent
        try addScript("setup", text: "#!/bin/sh\nprintf '\(name)\\n' >> \(NewTask.shellQuoted(marker))\n", to: repo)
    }
    let folder = try space.tasks.create(branch: "setups", repos: space.repos)
    let command = WorktreeScripts.starting("printf 'agent\\n' >> \(NewTask.shellQuoted(marker))", in: folder)

    try Git.run("/bin/sh", ["-c", command!], in: folder)

    #expect(try String(contentsOfFile: marker, encoding: .utf8) == "api\nweb\nagent\n")
}

@Test func teardownRunsOnlyWhenWorktreeIsRemoved() throws {
    let box = try Sandbox()
    let marker = URL(fileURLWithPath: box.repo).deletingLastPathComponent().appendingPathComponent("torn-down").path
    try addScript("teardown", text: "#!/bin/sh\ntouch \(NewTask.shellQuoted(marker))\n", to: box.repo)
    let path = try box.worktrees.create(branch: "teardown", from: box.repo)
    #expect(!FileManager.default.fileExists(atPath: marker))

    try box.worktrees.remove(path)

    #expect(FileManager.default.fileExists(atPath: marker))
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func failedTeardownKeepsWorktree() throws {
    let box = try Sandbox()
    try addScript("teardown", text: "#!/bin/sh\necho 'stop failed' >&2\nexit 1\n", to: box.repo)
    let path = try box.worktrees.create(branch: "kept", from: box.repo)

    #expect { try box.worktrees.remove(path) } throws: { "\($0)".contains("stop failed") }
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test func teardownDoesNotRunOnDirtyWorktree() throws {
    let box = try Sandbox()
    let marker = URL(fileURLWithPath: box.repo).deletingLastPathComponent().appendingPathComponent("torn-down").path
    try addScript("teardown", text: "#!/bin/sh\ntouch \(NewTask.shellQuoted(marker))\n", to: box.repo)
    let path = try box.worktrees.create(branch: "dirty", from: box.repo)
    try "draft".write(toFile: path + "/notes.txt", atomically: true, encoding: .utf8)

    #expect(throws: GitError.self) { try box.worktrees.remove(path) }
    #expect(!FileManager.default.fileExists(atPath: marker))
}
