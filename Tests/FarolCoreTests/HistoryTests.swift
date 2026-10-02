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
    let line = ["abc123def", "p1 p2", "Ana", "1700000000", "HEAD -> main, origin/main, tag: v1", "ana@example.com", "Merge a\u{1f}b"]
        .joined(separator: "\u{1f}")
    let commits = History.parse(line + "\n" + ["root", "", "Ana", "1600000000", "", "", "init"].joined(separator: "\u{1f}"))

    #expect(commits.count == 2)
    #expect(commits[0].parents == ["p1", "p2"])
    #expect(commits[0].refs == ["HEAD -> main", "origin/main", "tag: v1"])
    #expect(commits[0].subject == "Merge a\u{1f}b")
    #expect(commits[0].shortHash == "abc123d")
    #expect(commits[0].email == "ana@example.com")
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

    #expect(History.commitsAhead(of: "main", in: box.repo) == 1)
    #expect(History.commitsAhead(of: "feat", in: box.repo) == 0)

    try History.push(in: box.repo)
    #expect(History.branches(in: origin.repo).local.contains("feat"))
    #expect(try Git.run(["rev-parse", "--abbrev-ref", "feat@{upstream}"], in: box.repo) == "origin/feat")
}

@Test func commitsOnlyTheChosenFiles() throws {
    let box = try Sandbox()
    try Git.run(["config", "user.name", "Farol"], in: box.repo)
    try Git.run(["config", "user.email", "farol@example.com"], in: box.repo)
    func write(_ text: String, _ name: String) throws {
        try text.write(toFile: box.repo + "/" + name, atomically: true, encoding: .utf8)
    }
    for name in ["a.txt", "b.txt", "old.txt", "gone.txt"] { try write("base \(name)\n", name) }
    try History.commitAll("base", in: box.repo)

    try write("changed\n", "a.txt")
    try write("changed\n", "b.txt")
    try Git.run(["add", "b.txt"], in: box.repo)
    try Git.run(["mv", "old.txt", "new.txt"], in: box.repo)
    try FileManager.default.removeItem(atPath: box.repo + "/gone.txt")
    try write("new\n", "untracked.txt")
    try write("new\n", "left out.txt")

    #expect(Set(try Diff.uncommittedPaths(in: box.repo)) == ["a.txt", "b.txt", "new.txt", "gone.txt", "untracked.txt", "left out.txt"])
    try History.commit("part", only: ["a.txt", "new.txt", "old.txt", "gone.txt", "untracked.txt"], in: box.repo)

    #expect(try Git.run(["log", "-1", "--format=%s"], in: box.repo) == "part")
    let committed = try Git.run(["ls-tree", "-r", "--name-only", "HEAD"], in: box.repo).split(separator: "\n").map(String.init)
    #expect(committed == ["a.txt", "b.txt", "new.txt", "untracked.txt"])
    #expect(try Git.run(["show", "HEAD:b.txt"], in: box.repo) == "base b.txt")
    // What was left out is still there, and still staged if it was.
    let left = try Git.run(["status", "--porcelain"], in: box.repo, trimming: false).split(separator: "\n").map(String.init)
    #expect(left == ["M  b.txt", "?? \"left out.txt\""])
}

@Test func fetchesAndFastForwardsBranches() throws {
    let origin = try Sandbox()
    let box = try Sandbox()
    let commit = { (message: String, repo: String) in
        try Git.run(["-c", "user.name=Farol", "-c", "user.email=farol@example.com", "commit", "--quiet", "--allow-empty",
                     "-m", message], in: repo)
    }
    try Git.run(["remote", "add", "origin", origin.repo], in: box.repo)
    try Git.run(["branch", "gone"], in: origin.repo)
    try History.fetch(in: box.repo)
    try Git.run(["branch", "--quiet", "--set-upstream-to=origin/main", "main"], in: box.repo)
    try Git.run(["reset", "--quiet", "--hard", "origin/main"], in: box.repo)
    try Git.run(["branch", "--quiet", "--track", "side", "origin/main"], in: box.repo)
    #expect(History.upstreams(in: box.repo) == ["main": .init(name: "origin/main", ahead: 0, behind: 0),
                                                     "side": .init(name: "origin/main", ahead: 0, behind: 0)])

    // A branch deleted on the server goes away on the next fetch.
    try Git.run(["branch", "-D", "gone"], in: origin.repo)
    try commit("server work", origin.repo)
    try History.fetch(in: box.repo)
    #expect(!History.branches(in: box.repo).remote.contains("origin/gone"))
    #expect(History.upstreams(in: box.repo)["side"]?.behind == 1)
    #expect(History.oneSided(History.upstreams(in: box.repo), in: box.repo).count == 1)

    try History.update("side", current: false, in: box.repo)
    #expect(try History.commits(in: box.repo, branch: "side").first?.subject == "server work")
    try History.update("main", current: true, in: box.repo)
    #expect(try History.commits(in: box.repo, branch: "HEAD").first?.subject == "server work")

    // Once both sides have their own commits, neither update merges.
    try commit("local work", box.repo)
    try commit("more server work", origin.repo)
    #expect(throws: GitError.self) { try History.update("main", current: true, in: box.repo) }
    #expect(try History.commits(in: box.repo, branch: "HEAD").first?.subject == "local work")
    try Git.run(["branch", "--quiet", "--force", "side", "main"], in: box.repo)
    #expect(throws: GitError.self) { try History.update("side", current: false, in: box.repo) }

    // Pushing is never forced: main is behind the server, so it's refused until it catches up.
    #expect(throws: GitError.self) { try History.push("main", in: box.repo) }
    try Git.run(["-c", "user.name=Farol", "-c", "user.email=farol@example.com", "pull", "--quiet", "--rebase"], in: box.repo)
    // The server's main is checked out, so it takes the push only into another branch.
    try Git.run(["switch", "--quiet", "--detach"], in: origin.repo)
    try History.push("main", in: box.repo)
    #expect(History.upstreams(in: box.repo)["main"]?.ahead == 0)
    #expect(try History.commits(in: origin.repo, branch: "main").first?.subject == "local work")
}

@Test func dashesLanesLeadingDownFromOneSidedCommits() {
    // x and y are only on the local branch, a is on both.
    let rows = History.graph([commit("x", "y"), commit("y", "a"), commit("a")], oneSided: ["x", "y"])
    #expect(rows.map(\.oneSided) == [true, true, false])
    #expect(rows[1].dashedAbove == [true])
    #expect(rows[2].dashedAbove == [true])
    #expect(History.graph([commit("x", "a"), commit("a")]).allSatisfy { !$0.oneSided && !$0.dashedBelow.contains(true) })
}

@Test func findsTheCommitABranchPointsTo() {
    let commit = History.Commit(hash: "a", parents: [], author: "Ana", date: Date(), refs: ["HEAD -> main", "origin/main", "tag: v1"], subject: "init")
    #expect(commit.points("main"))
    #expect(commit.points("origin/main"))
    #expect(!commit.points("ma"))
    #expect(!commit.points("v1"))
}
