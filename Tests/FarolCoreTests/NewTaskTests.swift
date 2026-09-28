import Foundation
import Testing
@testable import FarolCore

@Test func branchFromTheFirstWords() {
    #expect(NewTask.branchName(for: "Add fuzzy search to the sidebar") == "add-fuzzy-search-to-the")
    #expect(NewTask.branchName(for: "Fix: flaky CI tests!") == "fix-flaky-ci-tests")
    #expect(NewTask.branchName(for: "   ") == "")
}

@Test func branchNamesAreValidForGit() {
    let branch = NewTask.branchName(for: "Update README.md & CHANGELOG (v2)")
    #expect(Worktrees.branchName(from: branch) == branch)
}

@Test func commandQuotesTheTask() {
    #expect(NewTask.command(.claude, task: "Fix the login bug") == "claude 'Fix the login bug'")
    #expect(NewTask.command(.codex, task: "it's done") == #"codex 'it'\''s done'"#)
}

/// Nothing in the task may run as a command, whatever it contains.
@Test func quotingKeepsShellCharactersLiteral() throws {
    let task = #"a $(touch /tmp/farol-pwned) `id` "q" 'x' \ && |"#
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", "printf %s \(NewTask.shellQuoted(task))"]
    let pipe = Pipe()
    shell.standardOutput = pipe
    try shell.run()
    shell.waitUntilExit()
    #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == task)
}
