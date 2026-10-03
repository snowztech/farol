import Foundation
import Testing
@testable import FarolCore

@Test func describesOnlyTheTickedFilesNewOnesIncluded() throws {
    let box = try Sandbox()
    let write = { (name: String, text: String) in try text.write(toFile: box.repo + "/" + name, atomically: true, encoding: .utf8) }
    try write("kept.txt", "one\n")
    try Git.run(["add", "kept.txt"], in: box.repo)
    try Git.run(["-c", "user.name=Farol", "-c", "user.email=farol@example.com", "commit", "--quiet", "-m", "add kept"], in: box.repo)
    try write("kept.txt", "two\n")
    try write("new.txt", "fresh\n")
    try write("left.txt", "not this one\n")

    let diff = try CommitMessage.diff(of: ["kept.txt", "new.txt"], in: box.repo)
    #expect(diff.contains("+two"))
    #expect(diff.contains("New file new.txt:\nfresh"))
    #expect(!diff.contains("left.txt"))
    #expect(try CommitMessage.diff(of: nil, in: box.repo).contains("New file left.txt"))
}

@Test func aBigDiffIsCut() throws {
    let box = try Sandbox()
    try String(repeating: "line\n", count: 30_000).write(toFile: box.repo + "/big.txt", atomically: true, encoding: .utf8)
    let diff = try CommitMessage.diff(of: nil, in: box.repo)
    #expect(diff.utf8.count < CommitMessage.diffLimit + 100)
    #expect(diff.hasSuffix("(diff cut here)\n"))
}

@Test func thePromptCarriesTheRecentSubjects() {
    let prompt = CommitMessage.prompt(diff: "+x", recent: ["feat: a", "fix: b"])
    #expect(prompt.contains("feat: a\nfix: b"))
    #expect(prompt.hasSuffix("+x"))
    #expect(CommitMessage.prompt(diff: "+x", recent: []).contains("(none yet)"))
}

@Test func takesOffWhatModelsAddAroundTheMessage() {
    #expect(CommitMessage.cleaned("feat: add x\n") == "feat: add x")
    #expect(CommitMessage.cleaned("Here is the commit message:\n\nfeat: add x") == "feat: add x")
    #expect(CommitMessage.cleaned("```\nfeat: add x\n```") == "feat: add x")
    #expect(CommitMessage.cleaned("\"feat: add x\"") == "feat: add x")
    #expect(CommitMessage.cleaned("`fix: y`") == "fix: y")
    // A body stays, with its blank line after the subject.
    #expect(CommitMessage.cleaned("feat: add x\n\nBecause y.") == "feat: add x\n\nBecause y.")
    #expect(CommitMessage.cleaned("  \n") == "")
    // An indented list keeps its shape, and quotes that are part of the message stay.
    #expect(CommitMessage.cleaned("feat: add x\n\n- one\n  - two\n") == "feat: add x\n\n- one\n  - two")
    #expect(CommitMessage.cleaned("`foo` replaces `bar`") == "`foo` replaces `bar`")
}

@Test func theAgentRunsWithoutTools() {
    let claude = CommitMessage.arguments(for: .claude)
    #expect(claude.contains("--tools"))
    #expect(claude.contains("--strict-mcp-config"))
    #expect(claude.contains { $0.contains("disableAllHooks") })
    #expect(CommitMessage.arguments(for: .codex).contains("read-only"))
}

@Test func anAgentThatQuitsWithoutReadingDoesNotKillTheApp() throws {
    // Bigger than the pipe, so the write is still going when the reader is gone. Unhandled, that's a SIGPIPE.
    let prompt = String(repeating: "x", count: 200_000)
    #expect(try CommitMessage.run("/usr/bin/true", [], input: prompt, environment: [:], in: NSTemporaryDirectory()) { _ in } == "")
}

@Test func whatTheAgentLogsOnStderrDoesNotStallIt() throws {
    // More than the pipe holds on stderr before anything on stdout.
    let script = "head -c 200000 /dev/zero | tr '\\0' e >&2 && cat >/dev/null && echo done"
    #expect(try CommitMessage.run("/bin/sh", ["-c", script], input: "hi", environment: [:], in: NSTemporaryDirectory()) { _ in } == "done\n")
}
