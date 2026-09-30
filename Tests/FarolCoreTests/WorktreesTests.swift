import Foundation
import Testing
@testable import FarolCore

/// A throwaway repo with one commit, plus a separate folder for worktrees.
struct Sandbox {
    let repo: String
    let worktrees: Worktrees

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("farol-tests-\(UUID().uuidString)")
        repo = root.appendingPathComponent("demo").path
        worktrees = Worktrees(base: root.appendingPathComponent("worktrees"))
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try Git.run(["init", "--quiet", "--initial-branch=main"], in: repo)
        try Git.run(["-c", "user.name=Farol", "-c", "user.email=farol@example.com", "commit", "--quiet", "--allow-empty", "-m", "init"], in: repo)
    }
}

@Test func branchNamesAreCleanedUp() {
    #expect(Worktrees.branchName(from: "Fix login bug") == "Fix-login-bug")
    #expect(Worktrees.branchName(from: "feat/tickets") == "feat/tickets")
    #expect(Worktrees.branchName(from: "a..b") == "a.b")
    #expect(Worktrees.branchName(from: "  ") == nil)
    #expect(Worktrees.branchName(from: "...") == nil)
}

@Test func createsWorktreeOnNewBranch() throws {
    let box = try Sandbox()
    let path = try box.worktrees.create(branch: "feat/x", from: box.repo)

    #expect(path.hasSuffix("worktrees/demo/feat-x"))
    #expect(Git.branch(of: path) == "feat/x")
    #expect(Git.branch(of: box.repo) == "main")
    #expect(Git.repoRoot(of: path).map { URL(fileURLWithPath: $0).lastPathComponent } == "demo")
    #expect(box.worktrees.contains(path))
    #expect(!box.worktrees.contains(box.repo))
}

@Test func checksOutExistingBranch() throws {
    let box = try Sandbox()
    try Git.run(["branch", "resume-me"], in: box.repo)
    let path = try box.worktrees.create(branch: "resume-me", from: box.repo)
    #expect(Git.branch(of: path) == "resume-me")
}

@Test func copiesIgnoredEnvironmentFiles() throws {
    let box = try Sandbox()
    try ".env\n.env.local\n.envrc\n".write(
        toFile: box.repo + "/.gitignore", atomically: true, encoding: .utf8)
    try Git.run(["add", ".gitignore"], in: box.repo)
    try Git.run([
        "-c", "user.name=Farol", "-c", "user.email=farol@example.com",
        "commit", "--quiet", "-m", "ignore local environment",
    ], in: box.repo)
    try "SEARCH_API=staging.search.com\n".write(
        toFile: box.repo + "/.env", atomically: true, encoding: .utf8)
    try "TOKEN=development\n".write(
        toFile: box.repo + "/.env.local", atomically: true, encoding: .utf8)
    try "SHARED=true\n".write(
        toFile: box.repo + "/.env.shared", atomically: true, encoding: .utf8)
    try "use flake\n".write(toFile: box.repo + "/.envrc", atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: box.repo + "/.env")

    let path = try box.worktrees.create(branch: "with-env", from: box.repo, copyEnvironmentFiles: true)

    #expect(try String(contentsOfFile: path + "/.env", encoding: .utf8) == "SEARCH_API=staging.search.com\n")
    #expect(try String(contentsOfFile: path + "/.env.local", encoding: .utf8) == "TOKEN=development\n")
    #expect(!FileManager.default.fileExists(atPath: path + "/.env.shared"))
    #expect(!FileManager.default.fileExists(atPath: path + "/.envrc"))
    let permissions = try FileManager.default.attributesOfItem(atPath: path + "/.env")[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    #expect(!box.worktrees.hasUncommittedChanges(path))
}

@Test func leavesEnvironmentFilesOutWhenCopyingIsDisabled() throws {
    let box = try Sandbox()
    try ".env\n".write(toFile: box.repo + "/.gitignore", atomically: true, encoding: .utf8)
    try "SEARCH_API=staging.search.com\n".write(
        toFile: box.repo + "/.env", atomically: true, encoding: .utf8)

    let path = try box.worktrees.create(branch: "without-env", from: box.repo)

    #expect(!FileManager.default.fileExists(atPath: path + "/.env"))
}

@Test func refusesSecondWorktreeAtSamePath() throws {
    let box = try Sandbox()
    _ = try box.worktrees.create(branch: "twice", from: box.repo)
    #expect(throws: GitError.self) { try box.worktrees.create(branch: "twice", from: box.repo) }
}

@Test func removingKeepsTheBranch() throws {
    let box = try Sandbox()
    let path = try box.worktrees.create(branch: "done", from: box.repo)
    try box.worktrees.remove(path)

    #expect(!FileManager.default.fileExists(atPath: path))
    #expect((try? Git.run(["rev-parse", "--verify", "refs/heads/done"], in: box.repo)) != nil)
}

@Test func removingRefusesUncommittedWork() throws {
    let box = try Sandbox()
    let path = try box.worktrees.create(branch: "wip", from: box.repo)
    try "draft".write(toFile: path + "/notes.txt", atomically: true, encoding: .utf8)

    #expect(throws: GitError.self) { try box.worktrees.remove(path) }
    #expect(FileManager.default.fileExists(atPath: path + "/notes.txt"))
}

@Test func seesUncommittedChanges() throws {
    let box = try Sandbox()
    let path = try box.worktrees.create(branch: "clean", from: box.repo)
    #expect(!box.worktrees.hasUncommittedChanges(path))
    try "draft".write(toFile: path + "/notes.txt", atomically: true, encoding: .utf8)
    #expect(box.worktrees.hasUncommittedChanges(path))
}

@Test func refusesToRemoveFoldersOutsideTheBase() throws {
    let box = try Sandbox()
    #expect(throws: GitError.self) { try box.worktrees.remove(box.repo) }
}

@Test func reportsNothingOutsideARepo() {
    #expect(Git.repoRoot(of: "/") == nil)
    #expect(Git.branch(of: "/") == nil)
}

@Test func findsWorktreeRootFromSubfolder() throws {
    let box = try Sandbox()
    let path = try box.worktrees.create(branch: "deep", from: box.repo)
    try FileManager.default.createDirectory(atPath: path + "/src/app", withIntermediateDirectories: true)

    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    #expect(box.worktrees.root(of: path + "/src/app") == resolved)
    #expect(box.worktrees.root(of: path) == resolved)
    #expect(box.worktrees.root(of: box.repo) == nil)
}
