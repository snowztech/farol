import Foundation
import Testing
@testable import FarolCore

@Test func readsGitHubRemotes() {
    for remote in ["git@github.com:snowztech/farol.git", "https://github.com/snowztech/farol.git",
                   "https://github.com/snowztech/farol", "ssh://git@github.com/snowztech/farol.git",
                   "https://token@github.com/snowztech/farol.git\n"] {
        let forge = Forge(remote: remote)
        #expect(forge?.kind == .github, "\(remote)")
        #expect(forge?.web == "https://github.com/snowztech/farol", "\(remote)")
    }
}

@Test func readsGitLabRemotesWithGroupsAndPorts() {
    #expect(Forge(remote: "git@gitlab.com:group/sub/app.git")?.web == "https://gitlab.com/group/sub/app")
    // The ssh port is dropped, a web port is kept.
    #expect(Forge(remote: "ssh://git@gitlab.example.com:2222/group/app.git")?.web == "https://gitlab.example.com/group/app")
    #expect(Forge(remote: "https://gitlab.example.com:8443/group/app.git")?.web == "https://gitlab.example.com:8443/group/app")
    #expect(Forge(remote: "http://gitlab.local/group/app")?.web == "http://gitlab.local/group/app")
    #expect(Forge(remote: "git@gitlab.com:group/app.git")?.kind == .gitlab)
}

@Test func otherRemotesAreNotForges() {
    #expect(Forge(remote: "git@bitbucket.org:team/app.git") == nil)
    #expect(Forge(remote: "/Users/ana/repos/app") == nil)
    #expect(Forge(remote: "") == nil)
}

@Test func linksToANewRequest() {
    let github = Forge(remote: "git@github.com:snowztech/farol.git")
    #expect(github?.newRequest(from: "feat/review#2")?.absoluteString
        == "https://github.com/snowztech/farol/compare/feat/review%232?expand=1")
    let gitlab = Forge(remote: "git@gitlab.com:group/app.git")
    #expect(gitlab?.newRequest(from: "feat/a&b")?.absoluteString
        == "https://gitlab.com/group/app/-/merge_requests/new?merge_request%5Bsource_branch%5D=feat/a%26b")
}

@Test func detectsTheForgeOfACheckout() throws {
    let box = try Sandbox()
    #expect(Forge.detect(in: box.repo) == nil)
    try Git.run(["remote", "add", "origin", "git@github.com:snowztech/farol.git"], in: box.repo)
    #expect(Forge.detect(in: box.repo)?.web == "https://github.com/snowztech/farol")
}

@Test func readsAnOpenRequestFromEitherTool() {
    #expect(Forge.request(from: #"[{"number":5,"url":"https://github.com/snowztech/farol/pull/5"}]"#)
        == .open(number: 5, url: URL(string: "https://github.com/snowztech/farol/pull/5")!))
    #expect(Forge.request(from: #"[{"iid":12,"web_url":"https://gitlab.com/group/app/-/merge_requests/12","title":"x"}]"#)
        == .open(number: 12, url: URL(string: "https://gitlab.com/group/app/-/merge_requests/12")!))
    #expect(Forge.request(from: "[]") == .none)
    // An error message, or a shape that isn't a list, says nothing either way.
    #expect(Forge.request(from: "no pull requests found") == .unknown)
    #expect(Forge.request(from: #"[{"title":"x"}]"#) == .unknown)
}

@Test func listsOpenRequestsByBranchFromEitherTool() {
    let github = #"""
    [{"number":97,"url":"https://github.com/snowztech/farol/pull/97","title":"Merge","headRefName":"feat/branch-merge","baseRefName":"main"},
     {"number":3,"url":"https://github.com/snowztech/farol/pull/3","title":"Fork","headRefName":"main","baseRefName":"main"}]
    """#
    #expect(Forge.requests(from: github) == ["feat/branch-merge": Forge.Request(
        number: 97, url: URL(string: "https://github.com/snowztech/farol/pull/97")!, title: "Merge")])
    let gitlab = #"[{"iid":12,"web_url":"https://gitlab.com/group/app/-/merge_requests/12","title":"x","source_branch":"fix","target_branch":"main"}]"#
    #expect(Forge.requests(from: gitlab)["fix"]?.number == 12)
    #expect(Forge.requests(from: "not logged in").isEmpty)
}

@Test func readsARequestsChecksFromEitherTool() {
    let github = #"""
    [{"statusCheckRollup":[
      {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com/o/r/actions/runs/1/job/2"},
      {"__typename":"CheckRun","name":"lint","status":"IN_PROGRESS","conclusion":""},
      {"__typename":"CheckRun","name":"docs","status":"COMPLETED","conclusion":"SKIPPED"},
      {"__typename":"StatusContext","context":"deploy","state":"FAILURE","targetUrl":"https://ci.example.com/7"}]}]
    """#
    let checks = Forge.checks(from: github)
    #expect(checks.map(\.name) == ["deploy", "lint", "test", "docs"])
    #expect(checks.map(\.state) == [.failed, .running, .passed, .skipped])
    #expect(checks[2].url?.absoluteString == "https://github.com/o/r/actions/runs/1/job/2")
    let gitlab = #"{"id":9,"status":"running","jobs":[{"name":"build","status":"success","web_url":"https://gitlab.com/g/a/-/jobs/1"},{"name":"test","status":"pending"},{"name":"release","status":"manual"}]}"#
    #expect(Forge.checks(from: gitlab).map(\.state) == [.running, .passed, .skipped])
    #expect(Forge.checks(from: "[]").isEmpty)
    #expect(Forge.checks(from: "not logged in").isEmpty)
}

@Test func readsTheAccountFromEitherToolsStatus() {
    #expect(Forge.Kind.account(from: "github.com\n  ✓ Logged in to github.com account ana (keyring)\n  - Active account: true") == "ana")
    #expect(Forge.Kind.account(from: "gitlab.com\n  ✓ Logged in to gitlab.com as ana (GITLAB_TOKEN)") == "ana")
    #expect(Forge.Kind.account(from: "You are not logged into any GitHub hosts.") == nil)
}

@Test func setupInstallsOnlyWhenTheToolIsMissing() {
    #expect(Forge.Kind.github.setupCommand(from: .missing) == "brew install gh && gh auth login")
    #expect(Forge.Kind.gitlab.setupCommand(from: .loggedOut) == "glab auth login")
}

@Test func findsTheAccountsPicture() {
    #expect(Forge.Kind.github.avatar(of: "ana")?.absoluteString == "https://github.com/ana.png?size=64")
    #expect(Forge.Kind.avatar(fromUser: #"{"username":"ana","avatar_url":"https://gitlab.com/uploads/-/system/user/avatar/7/a.png"}"#)?.absoluteString
        == "https://gitlab.com/uploads/-/system/user/avatar/7/a.png")
    // GitLab sends null for an account with no picture.
    #expect(Forge.Kind.avatar(fromUser: #"{"username":"ana","avatar_url":null}"#) == nil)
    #expect(Forge.Kind.avatar(fromUser: "not logged in") == nil)
}

@Test func readsARequestsDiscussionFromGitHub() throws {
    let view = #"""
    {"author":{"login":"ana"},"body":"Adds a thing.","createdAt":"2026-10-14T10:00:00Z","url":"https://github.com/o/r/pull/3","headRefOid":"abc123",
     "comments":[{"author":{"login":"bo"},"body":"Thanks","createdAt":"2026-10-14T12:00:00Z","url":"https://github.com/o/r/pull/3#c1"}],
     "reviews":[{"author":{"login":"cy"},"body":"","state":"APPROVED","submittedAt":"2026-10-14T13:00:00Z"},
                {"author":{"login":"cy"},"body":"","state":"COMMENTED","submittedAt":"2026-10-14T11:30:00Z"}]}
    """#
    let lines = #"[{"user":{"login":"cy"},"body":"Why here?","created_at":"2026-10-14T11:00:00Z","path":"a.swift","line":null,"original_line":7,"side":"LEFT"}]"#
    let discussion = try #require(Forge.discussion(github: view, lines: lines))
    #expect(discussion.description.author == "ana")
    #expect(discussion.description.text == "Adds a thing.")
    // Oldest first, and a review with neither text nor verdict only stood for its comments on lines.
    #expect(discussion.comments.map(\.author) == ["cy", "bo", "cy"])
    #expect(discussion.comments[0].path == "a.swift")
    #expect(discussion.comments[0].line == 7)
    #expect(discussion.comments[0].old)
    // Its line is gone, so it stays in the conversation rather than under a line that moved.
    #expect(discussion.comments[0].outdated)
    #expect(discussion.head == "abc123")
    #expect(discussion.comments[2].verdict == "approved")
    #expect(Forge.discussion(github: "not logged in", lines: "[]") == nil)
}

@Test func readsARequestsDiscussionFromGitLab() throws {
    let request = #"{"description":"Fixes it.","author":{"username":"ana"},"created_at":"2026-10-14T10:00:00.123Z","web_url":"https://gitlab.com/g/a/-/merge_requests/3","diff_refs":{"base_sha":"b1","start_sha":"s1","head_sha":"h1"}}"#
    let notes = #"""
    [{"id":7,"body":"added 1 commit","system":true,"author":{"username":"ana"}},
     {"id":8,"body":"Why?","system":false,"author":{"username":"bo"},"created_at":"2026-10-15T08:00:00.000Z","position":{"new_path":"a.swift","new_line":12}},
     {"id":9,"body":"Gone?","system":false,"author":{"username":"bo"},"position":{"new_path":"a.swift","new_line":null,"old_line":4}}]
    """#
    let discussion = try #require(Forge.discussion(gitlab: request, notes: notes))
    #expect(discussion.description.date != nil)
    #expect(discussion.comments.count == 2)
    #expect(discussion.comments[0].path == "a.swift")
    #expect(discussion.comments[0].line == 12)
    #expect(!discussion.comments[0].old)
    // A note on a removed line counts in the old file.
    #expect(discussion.comments[1].line == 4)
    #expect(discussion.comments[1].old)
    #expect(discussion.comments[0].url?.absoluteString == "https://gitlab.com/g/a/-/merge_requests/3#note_8")
    // The three commits a new comment on a line names.
    #expect(discussion.base == "b1")
    #expect(discussion.start == "s1")
    #expect(discussion.head == "h1")
}

@Test func placesAGitLabCommentOnALine() throws {
    let request = #"{"description":"","author":{"username":"ana"},"diff_refs":{"base_sha":"b1","start_sha":"s1","head_sha":"h1"}}"#
    let discussion = try #require(Forge.discussion(gitlab: request, notes: "[]"))
    // A line the request leaves alone needs its number on both sides, and a renamed file both paths.
    let unchanged = Forge.LinePlace(path: "new.swift", oldPath: "old.swift", newLine: 13, oldLine: 12)
    let body = try #require(Forge.gitlabComment("Why?", at: unchanged, of: discussion))
    #expect(body["body"] as? String == "Why?")
    let position = try #require(body["position"] as? [String: Any])
    #expect(position["position_type"] as? String == "text")
    #expect(position["base_sha"] as? String == "b1")
    #expect(position["start_sha"] as? String == "s1")
    #expect(position["head_sha"] as? String == "h1")
    #expect(position["new_path"] as? String == "new.swift")
    #expect(position["old_path"] as? String == "old.swift")
    #expect(position["new_line"] as? Int == 13)
    #expect(position["old_line"] as? Int == 12)
    // A removed line has only its old number.
    let removed = Forge.LinePlace(path: "a.swift", oldPath: "a.swift", newLine: nil, oldLine: 4)
    let removedPosition = try #require(Forge.gitlabComment("Gone?", at: removed, of: discussion)?["position"] as? [String: Any])
    #expect(removedPosition["new_line"] == nil)
    #expect(removedPosition["old_line"] as? Int == 4)
    // Without the diff's commits there is nothing to place it against.
    #expect(Forge.gitlabComment("x", at: removed, of: Forge.discussion(gitlab: #"{"description":""}"#, notes: "[]")!) == nil)
}
