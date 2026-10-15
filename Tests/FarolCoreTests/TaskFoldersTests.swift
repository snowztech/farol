import Foundation
import Testing
@testable import FarolCore

/// A parent folder with two repos and a plain folder in it, plus a separate folder for tasks.
struct Workspace {
    let parent: String
    let tasks: TaskFolders

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("farol-tests-\(UUID().uuidString)")
        parent = root.appendingPathComponent("company").path
        tasks = TaskFolders(base: root.appendingPathComponent("tasks"))
        for name in ["web", "api"] {
            let repo = parent + "/" + name
            try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
            try Git.run(["init", "--quiet", "--initial-branch=main"], in: repo)
            try Git.run(["-c", "user.name=Farol", "-c", "user.email=farol@example.com", "commit", "--quiet", "--allow-empty", "-m", "init"], in: repo)
        }
        try FileManager.default.createDirectory(atPath: parent + "/notes", withIntermediateDirectories: true)
    }

    var repos: [String] { [parent + "/api", parent + "/web"] }
}

@Test func findsReposInsideAFolder() throws {
    let space = try Workspace()
    #expect(TaskFolders.repos(in: space.parent) == space.repos)
    #expect(TaskFolders.repos(in: space.parent + "/api").isEmpty)
}

@Test func createsAWorktreeOfEachRepoOnOneBranch() throws {
    let space = try Workspace()
    let folder = try space.tasks.create(branch: "PROJ-1/billing", repos: space.repos)

    #expect(folder.hasSuffix("tasks/PROJ-1-billing"))
    #expect(Git.branch(of: folder + "/api") == "PROJ-1/billing")
    #expect(Git.branch(of: folder + "/web") == "PROJ-1/billing")
    #expect(Git.branch(of: space.parent + "/api") == "main")
    #expect(space.tasks.root(of: folder + "/web") == URL(fileURLWithPath: folder).resolvingSymlinksInPath().path)
    #expect(space.tasks.root(of: space.parent) == nil)
}

@Test func failingRepoLeavesNothingBehind() throws {
    let space = try Workspace()
    // web can't check out a branch api already has checked out in another worktree.
    try Git.run(["branch", "taken"], in: space.parent + "/web")
    _ = try Git.run(["worktree", "add", space.parent + "/../web-taken", "taken"], in: space.parent + "/web")

    #expect(throws: GitError.self) { try space.tasks.create(branch: "taken", repos: space.repos) }
    #expect(!FileManager.default.fileExists(atPath: space.tasks.base.appendingPathComponent("taken").path))
    #expect((try? Git.run(["rev-parse", "--verify", "refs/heads/taken"], in: space.parent + "/api")) != nil)
}

@Test func removingTheTaskKeepsTheBranches() throws {
    let space = try Workspace()
    let folder = try space.tasks.create(branch: "done", repos: space.repos)
    #expect(!space.tasks.hasUncommittedChanges(folder))

    try space.tasks.remove(folder)
    #expect(!FileManager.default.fileExists(atPath: folder))
    for repo in space.repos {
        #expect((try? Git.run(["rev-parse", "--verify", "refs/heads/done"], in: repo)) != nil)
    }
}

@Test func seesWorkInAnyRepoOrBesideThem() throws {
    let space = try Workspace()
    let folder = try space.tasks.create(branch: "wip", repos: space.repos)
    try "draft".write(toFile: folder + "/web/notes.txt", atomically: true, encoding: .utf8)
    #expect(space.tasks.hasUncommittedChanges(folder))

    try FileManager.default.removeItem(atPath: folder + "/web/notes.txt")
    try "plan".write(toFile: folder + "/PLAN.md", atomically: true, encoding: .utf8)
    #expect(space.tasks.hasUncommittedChanges(folder))

    // The worktrees go, the agent's file and so the folder stay.
    try space.tasks.remove(folder)
    #expect(FileManager.default.fileExists(atPath: folder + "/PLAN.md"))
    #expect(!FileManager.default.fileExists(atPath: folder + "/web"))
}

@Test func refusesToRemoveFoldersOutsideTasks() throws {
    let space = try Workspace()
    #expect(throws: GitError.self) { try space.tasks.remove(space.parent) }
}
