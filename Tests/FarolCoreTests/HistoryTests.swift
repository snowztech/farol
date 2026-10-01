import Foundation
import Testing
@testable import FarolCore

private func commit(_ hash: String, _ parents: String...) -> History.Commit {
    History.Commit(hash: hash, parents: parents, author: "Farol", date: Date(timeIntervalSince1970: 0), refs: [], subject: hash)
}

private func edges(_ pairs: (Int, Int)...) -> [History.Edge] {
    pairs.map { History.Edge(from: $0.0, to: $0.1) }
}

@Test func parsesLogLines() {
    let line = ["abc123def", "p1 p2", "Ana", "1700000000", "HEAD -> main, origin/main, tag: v1", "Merge a\u{1f}b"]
        .joined(separator: "\u{1f}")
    let commits = History.parse(line + "\n" + ["root", "", "Ana", "1600000000", "", "init"].joined(separator: "\u{1f}"))

    #expect(commits.count == 2)
    #expect(commits[0].parents == ["p1", "p2"])
    #expect(commits[0].refs == ["HEAD -> main", "origin/main", "tag: v1"])
    #expect(commits[0].subject == "Merge a\u{1f}b")
    #expect(commits[0].shortHash == "abc123d")
    #expect(commits[1].parents.isEmpty)
    #expect(commits[1].refs.isEmpty)
}

@Test func straightHistoryStaysInOneLane() {
    let rows = History.graph([commit("c", "b"), commit("b", "a"), commit("a")])
    #expect(rows.map(\.column) == [0, 0, 0])
    #expect(rows[0].top.isEmpty)
    #expect(rows[0].bottom == edges((0, 0)))
    #expect(rows[1].top == edges((0, 0)))
    #expect(rows[2].bottom.isEmpty)
}

@Test func branchAndMergeOpenASecondLaneAndCloseIt() {
    // m merges f into main. f and b both come from a.
    let rows = History.graph([commit("m", "b", "f"), commit("f", "a"), commit("b", "a"), commit("a")])
    #expect(rows.map(\.column) == [0, 1, 0, 0])
    #expect(rows[0].bottom == edges((0, 0), (0, 1)))
    #expect(rows[1].bottom == edges((0, 0), (1, 1)))
    // Both lanes run down to a, and meet there in the leftmost one.
    #expect(rows[2].bottom == edges((1, 1), (0, 0)))
    #expect(rows[3].top == edges((0, 0), (1, 0)))
}

@Test func everyTipKeepsItsOwnLane() {
    // Three branches forked from a. Each gets a lane, like a fan, and they all meet at a.
    let rows = History.graph([commit("x", "a"), commit("y", "a"), commit("z", "a"), commit("a")])
    #expect(rows.map(\.column) == [0, 1, 2, 0])
    #expect(rows[3].top == edges((0, 0), (1, 0), (2, 0)))
    #expect(rows.map(\.color) == [0, 1, 2, 0])
}

@Test func aReusedLaneGetsANewColor() {
    // y ends at a, so z reuses lane 1 but is another branch and gets its own color.
    let rows = History.graph([commit("x", "b"), commit("y", "b"), commit("b", "a"), commit("z", "a"), commit("a")])
    #expect(rows.map(\.column) == [0, 1, 0, 1, 0])
    #expect(rows.map(\.color) == [0, 1, 0, 2, 0])
    #expect(rows[3].colorsBelow == [0, 2])
}

@Test func twoTipsJoinAtTheirParent() {
    let rows = History.graph([commit("x", "a"), commit("y", "a"), commit("a")])
    #expect(rows.map(\.column) == [0, 1, 0])
    #expect(rows[1].bottom == edges((0, 0), (1, 1)))
    #expect(rows[2].top == edges((0, 0), (1, 0)))
}

@Test func readsARealRepo() throws {
    let box = try Sandbox()
    let git = { (args: [String]) in
        try Git.run(["-c", "user.name=Farol", "-c", "user.email=farol@example.com"] + args, in: box.repo)
    }
    try git(["switch", "--quiet", "-c", "feat"])
    try git(["commit", "--quiet", "--allow-empty", "-m", "feature work"])
    try git(["switch", "--quiet", "main"])
    try git(["commit", "--quiet", "--allow-empty", "-m", "main work"])

    let branches = History.branches(in: box.repo)
    #expect(Set(branches.local) == ["main", "feat"])
    #expect(branches.remote.isEmpty)

    let all = try History.commits(in: box.repo, branch: nil)
    #expect(Set(all.map(\.subject)) == ["feature work", "main work", "init"])
    let feat = try History.commits(in: box.repo, branch: "feat")
    #expect(feat.map(\.subject) == ["feature work", "init"])
    #expect(History.graph(all).map(\.column) == [0, 1, 0])

    try History.checkout("feat", remote: false, in: box.repo)
    #expect(Git.branch(of: box.repo) == "feat")
}

@Test func checkingOutACommitPrefersItsBranch() throws {
    let box = try Sandbox()
    try Git.run(["-c", "user.name=Farol", "-c", "user.email=farol@example.com", "commit", "--quiet", "--allow-empty",
                 "-m", "second"], in: box.repo)
    try Git.run(["branch", "feat"], in: box.repo)
    try Git.run(["switch", "--quiet", "--detach", "HEAD~1"], in: box.repo)
    let commits = try History.commits(in: box.repo, branch: nil)

    try History.checkout(commits.first { $0.subject == "second" }!, in: box.repo)
    #expect(Git.branch(of: box.repo) == "feat" || Git.branch(of: box.repo) == "main")

    let root = commits.first { $0.subject == "init" }!
    try History.checkout(root, in: box.repo)
    #expect(Git.branch(of: box.repo) == nil)
    #expect(try Git.run(["rev-parse", "HEAD"], in: box.repo) == root.hash)
}

@Test func checkingOutARemoteBranchTracksIt() throws {
    let origin = try Sandbox()
    let box = try Sandbox()
    try Git.run(["remote", "add", "origin", origin.repo], in: box.repo)
    try Git.run(["-c", "user.name=Farol", "-c", "user.email=farol@example.com", "commit", "--quiet", "--allow-empty",
                 "-m", "remote work"], in: origin.repo)
    try Git.run(["branch", "shared"], in: origin.repo)
    try Git.run(["fetch", "--quiet", "origin"], in: box.repo)
    #expect(History.branches(in: box.repo).remote.contains("origin/shared"))

    try History.checkout("origin/shared", remote: true, in: box.repo)
    #expect(Git.branch(of: box.repo) == "shared")
    #expect(try Git.run(["rev-parse", "--abbrev-ref", "shared@{upstream}"], in: box.repo) == "origin/shared")

    // Once the local branch exists, the remote entry goes back to it.
    try Git.run(["switch", "--quiet", "main"], in: box.repo)
    try History.checkout("origin/shared", remote: true, in: box.repo)
    #expect(Git.branch(of: box.repo) == "shared")

    try History.deleteRemoteBranch("origin/shared", in: box.repo)
    #expect(!History.branches(in: origin.repo).local.contains("shared"))
    #expect(!History.branches(in: box.repo).remote.contains("origin/shared"))
    // The local branch is left alone.
    #expect(History.branches(in: box.repo).local.contains("shared"))
}

@Test func createsDeletesRebasesAndCherryPicks() throws {
    let box = try Sandbox()
    let git = { (args: [String]) in
        try Git.run(["-c", "user.name=Farol", "-c", "user.email=farol@example.com"] + args, in: box.repo)
    }
    try History.createBranch("feat", from: "main", in: box.repo)
    #expect(Git.branch(of: box.repo) == "feat")
    try "a".write(toFile: box.repo + "/a.txt", atomically: true, encoding: .utf8)
    try git(["add", "a.txt"])
    try git(["commit", "--quiet", "-m", "add a"])

    try git(["switch", "--quiet", "main"])
    try "b".write(toFile: box.repo + "/b.txt", atomically: true, encoding: .utf8)
    try git(["add", "b.txt"])
    try git(["commit", "--quiet", "-m", "add b"])

    // feat isn't merged into main, so a plain delete refuses and a forced one goes through.
    #expect(throws: GitError.self) { try History.deleteBranch("feat", force: false, in: box.repo) }

    let pick = try History.commits(in: box.repo, branch: "feat").first { $0.subject == "add a" }!
    try git(["switch", "--quiet", "-c", "other", "main~1"])
    // Cherry-pick and rebase write commits too, and read who from the config.
    try git(["config", "user.name", "Farol"])
    try git(["config", "user.email", "farol@example.com"])
    try History.cherryPick(pick, in: box.repo)
    #expect(FileManager.default.fileExists(atPath: box.repo + "/a.txt"))

    try History.rebase(onto: "main", in: box.repo)
    #expect(try History.commits(in: box.repo, branch: "HEAD").map(\.subject) == ["add a", "add b", "init"])

    try git(["switch", "--quiet", "main"])
    try History.deleteBranch("feat", force: true, in: box.repo)
    #expect(!History.branches(in: box.repo).local.contains("feat"))
}

@Test func interactiveRebaseQuotesTheBranch() {
    #expect(History.interactiveRebaseCommand(onto: "origin/main") == "git rebase --interactive 'origin/main'")
    #expect(History.interactiveRebaseCommand(onto: "it's") == "git rebase --interactive 'it'\\''s'")
}

@Test func revertsACommitWithANewOne() throws {
    let box = try Sandbox()
    try Git.run(["config", "user.name", "Farol"], in: box.repo)
    try Git.run(["config", "user.email", "farol@example.com"], in: box.repo)
    for name in ["a", "b"] {
        try name.write(toFile: box.repo + "/\(name).txt", atomically: true, encoding: .utf8)
        try Git.run(["add", "\(name).txt"], in: box.repo)
        try Git.run(["commit", "--quiet", "-m", "add \(name)"], in: box.repo)
    }
    let a = try History.commits(in: box.repo, branch: "HEAD").first { $0.subject == "add a" }!

    try History.revert(a, in: box.repo)
    #expect(try History.commits(in: box.repo, branch: "HEAD").map(\.subject) == ["Revert \"add a\"", "add b", "add a", "init"])
    #expect(!FileManager.default.fileExists(atPath: box.repo + "/a.txt"))
    #expect(FileManager.default.fileExists(atPath: box.repo + "/b.txt"))
}

@Test func commitsEverythingAndPushes() throws {
    let origin = try Sandbox()
    let box = try Sandbox()
    try Git.run(["remote", "add", "origin", origin.repo], in: box.repo)
    try Git.run(["config", "user.name", "Farol"], in: box.repo)
    try Git.run(["config", "user.email", "farol@example.com"], in: box.repo)
    try History.createBranch("feat", from: "main", in: box.repo)

    try "staged".write(toFile: box.repo + "/staged.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "staged.txt"], in: box.repo)
    try "new".write(toFile: box.repo + "/untracked.txt", atomically: true, encoding: .utf8)
    try History.commitAll("add files", in: box.repo)

    #expect(try Git.run(["status", "--porcelain"], in: box.repo).isEmpty)
    #expect(try Git.run(["log", "-1", "--format=%s"], in: box.repo) == "add files")
    // Nothing is left to commit, and git says so.
    #expect(throws: GitError.self) { try History.commitAll("again", in: box.repo) }

    try History.push(in: box.repo)
    #expect(History.branches(in: origin.repo).local.contains("feat"))
    #expect(try Git.run(["rev-parse", "--abbrev-ref", "feat@{upstream}"], in: box.repo) == "origin/feat")
}
