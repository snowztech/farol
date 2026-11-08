import Foundation
import Testing
@testable import FarolCore

@Test func readsLinearIssuesAfterWhatTheShellPrinted() {
    let output = """
    welcome back [from a startup file]
    {
      "data": {"viewer": {"assignedIssues": {"nodes": [
        {"identifier": "ENG-12", "title": "Fix the login", "description": "Users can't log in.\\n\\n- check the token\\n", "url": "https://linear.app/acme/issue/ENG-12/fix-the-login"},
        {"identifier": "ENG-13", "title": "Nothing written", "description": null, "url": "https://linear.app/acme/issue/ENG-13"},
        {"title": "No identifier, so left out"}
      ]}}}
    }
    """
    #expect(Linear.tickets(from: output) == [
        Ticket(source: .linear, key: "ENG-12", summary: "Fix the login", description: "Users can't log in.\n\n- check the token",
               url: URL(string: "https://linear.app/acme/issue/ENG-12/fix-the-login")),
        Ticket(source: .linear, key: "ENG-13", summary: "Nothing written", description: "", url: URL(string: "https://linear.app/acme/issue/ENG-13")),
    ])
    // Without the "data" wrapper too, and nothing from an error or an empty answer.
    #expect(Linear.tickets(from: #"{"viewer": {"assignedIssues": {"nodes": [{"identifier": "A-1", "title": "One"}]}}}"#).map(\.key) == ["A-1"])
    #expect(Linear.tickets(from: "error: not logged in").isEmpty)
}

@Test func asksForOpenIssuesOnly() {
    #expect(Linear.query.contains(#"nin: ["completed", "canceled"]"#))
    #expect(Linear.query.contains("description"))
}
