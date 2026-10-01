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

@Test func readsTheAccountFromEitherToolsStatus() {
    #expect(Forge.Kind.account(from: "github.com\n  ✓ Logged in to github.com account ana (keyring)\n  - Active account: true") == "ana")
    #expect(Forge.Kind.account(from: "gitlab.com\n  ✓ Logged in to gitlab.com as ana (GITLAB_TOKEN)") == "ana")
    #expect(Forge.Kind.account(from: "You are not logged into any GitHub hosts.") == nil)
}

@Test func setupInstallsOnlyWhenTheToolIsMissing() {
    #expect(Forge.Kind.github.setupCommand(from: .missing) == "brew install gh && gh auth login")
    #expect(Forge.Kind.gitlab.setupCommand(from: .loggedOut) == "glab auth login")
}
