import Foundation
import Testing
@testable import FarolCore

private func prompt(_ json: String) -> AgentPrompt? {
    AgentPrompt(hookInput: Data(json.utf8))
}

@Test func readsAQuestionWithItsOptions() {
    let result = prompt("""
    {"tool_name": "AskUserQuestion", "tool_input": {"questions": [
      {"question": "Which database?", "header": "DB", "options": [{"label": "Postgres"}, {"label": "SQLite", "description": "Local"}]}
    ]}}
    """)
    #expect(result == AgentPrompt(text: "Which database?", options: ["Postgres", "SQLite"]))
}

@Test func countsTheQuestionsNotShown() {
    let result = prompt("""
    {"tool_input": {"questions": [
      {"question": "Which database?", "options": [{"label": "Postgres"}]},
      {"question": "Which checks?", "options": [{"label": "Lint"}]}
    ]}}
    """)
    #expect(result == AgentPrompt(text: "Which database? (+1 more)", options: ["Postgres"]))
}

@Test func readsAPermissionMessage() {
    let result = prompt(#"{"hook_event_name": "Notification", "message": "Claude needs your permission to use Bash"}"#)
    #expect(result == AgentPrompt(text: "Claude needs your permission to use Bash"))
}

@Test func aQuestionWinsOverTheMessage() {
    let result = prompt(#"{"message": "waiting", "tool_input": {"questions": [{"question": "Go?", "options": []}]}}"#)
    #expect(result == AgentPrompt(text: "Go?"))
}

@Test func givesNilForAnythingElse() {
    #expect(prompt("") == nil)
    #expect(prompt("not json") == nil)
    #expect(prompt("[1, 2]") == nil)
    #expect(prompt(#"{"tool_input": {"command": "ls"}}"#) == nil)
    #expect(prompt(#"{"message": "  "}"#) == nil)
    #expect(prompt(#"{"tool_input": {"questions": [{"options": [{"label": "A"}]}]}}"#) == nil)
}

@Test func skipsOptionsWithoutALabel() {
    let result = prompt(#"{"tool_input": {"questions": [{"question": "Go?", "options": [{"label": "Yes"}, {}, {"label": ""}]}]}}"#)
    #expect(result?.options == ["Yes"])
}

@Test func summaryJoinsTheOptions() {
    #expect(AgentPrompt(text: "Which database?", options: ["Postgres", "SQLite"]).summary() == "Which database? Postgres · SQLite")
    #expect(AgentPrompt(text: "Allow Bash?").summary() == "Allow Bash?")
}

@Test func summaryIsCutToFit() {
    let long = AgentPrompt(text: String(repeating: "a", count: 300))
    #expect(long.summary(limit: 50).count == 50)
    #expect(long.summary(limit: 50).hasSuffix("…"))
}
