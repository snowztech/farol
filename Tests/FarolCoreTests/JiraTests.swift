import Foundation
import Testing
@testable import FarolCore

@Test func readsTicketsAfterWhatTheShellPrinted() {
    let output = """
    welcome back [from a startup file]
    [
      {"key": "CMB-12", "self": "https://acme.atlassian.net/rest/api/3/issue/10012", "fields": {"summary": "Fix the login", "description": {"type": "doc", "content": [
        {"type": "paragraph", "content": [{"type": "text", "text": "Users of "},
          {"type": "mention", "attrs": {"id": "1", "text": "@ana"}}, {"type": "text", "text": " can't log in."}]},
        {"type": "bulletList", "content": [
          {"type": "listItem", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "check the token"}]}]}]}
      ]}}},
      {"key": "CMB-13", "self": "https://jira.acme.com/jira/rest/api/2/issue/13", "fields": {"summary": "From Data Center", "description": "Plain text."}},
      {"key": "CMB-14", "fields": {"summary": "Nothing written", "description": null}}
    ]
    """
    #expect(Jira.tickets(from: output) == [
        Ticket(source: .jira, key: "CMB-12", summary: "Fix the login", description: "Users of @ana can't log in.\n- check the token",
               url: URL(string: "https://acme.atlassian.net/browse/CMB-12")),
        Ticket(source: .jira, key: "CMB-13", summary: "From Data Center", description: "Plain text.",
               url: URL(string: "https://jira.acme.com/jira/browse/CMB-13")),
        Ticket(source: .jira, key: "CMB-14", summary: "Nothing written", description: "", url: nil),
    ])
    #expect(Jira.tickets(from: "The tool needs a Jira API token to function.") == [])
}

@Test func ticketBecomesATaskAndABranch() {
    let url = URL(string: "https://acme.atlassian.net/browse/CMB-12")
    let ticket = Ticket(source: .jira, key: "CMB-12", summary: "Fix the login (again)!", description: "Step:\tretry", url: url)
    #expect(ticket.task == "CMB-12: Fix the login (again)!\nhttps://acme.atlassian.net/browse/CMB-12\n\nStep:\tretry")
    #expect(ticket.branch == "CMB-12-fix-the-login-again")
    #expect(Worktrees.branchName(from: ticket.branch) == ticket.branch)
    #expect(Ticket(source: .jira, key: "CMB-14", summary: "Nothing written", description: "", url: nil).task == "CMB-14: Nothing written")
}

@Test func readsGitHubIssues() {
    let json = #"[{"number": 41, "title": "Support multiple accounts", "body": "One.\r\nTwo.\r\n", "url": "https://github.com/acme/app/issues/41"}, {"number": 7, "title": "No body"}]"#
    let issues = Forge.issues(from: json)
    #expect(issues.map(\.key) == ["#41", "#7"])
    #expect(issues[0].task == "#41: Support multiple accounts\nhttps://github.com/acme/app/issues/41\n\nOne.\nTwo.")
    #expect(issues[0].branch == "41-support-multiple-accounts")
    #expect(issues[1].task == "#7: No body")
    #expect(Forge.issues(from: "not logged in") == [])
}

@Test func readsGitLabIssues() {
    let json = #"[{"iid": 12, "title": "Fix the pipeline", "description": "It fails.", "web_url": "https://gitlab.com/g/app/-/issues/12"}]"#
    let issues = Forge.issues(from: json, source: .gitlab)
    #expect(issues == [Ticket(source: .gitlab, key: "#12", summary: "Fix the pipeline", description: "It fails.",
                              url: URL(string: "https://gitlab.com/g/app/-/issues/12"))])
}

@Test func readsTheJiraAccountsPicture() {
    let user = #"{"self": "https://x.atlassian.net/rest/api/2/user", "avatarUrls": {"48x48": "https://avatars.example/ana.png"}}"#
    #expect(Jira.avatar(fromUser: "hello\n" + user) == URL(string: "https://avatars.example/ana.png"))
    #expect(Jira.avatar(fromUser: "curl: (22) The requested URL returned error: 401") == nil)
}

@Test func readsBoardsAndABoardsTickets() {
    let list = "ID\tNAME\t\t\t\tTYPE\n474\tCMB BE Board\t\t\t\tscrum\n2598\tDemand Bugs Kanban board\t\tkanban\n"
    let boards = list.split(separator: "\n").compactMap { Jira.Board(line: String($0)) }
    #expect(boards.map(\.id) == [474, 2598])
    #expect(boards.map(\.name) == ["CMB BE Board", "Demand Bugs Kanban board"])
    #expect(boards.map(\.sprints) == [true, false])
    #expect(Jira.Board(line: boards[0].line) == boards[0])
    #expect(Jira.Board(line: "") == nil)

    let answer = #"{"total": 1, "issues": [{"id": "1", "key": "CMB-20", "fields": {"summary": "On the board", "description": "h2. Why"}}]}"#
    #expect(Jira.tickets(from: answer) == [Ticket(source: .jira, key: "CMB-20", summary: "On the board", description: "h2. Why", url: nil)])
}
