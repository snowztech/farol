import Foundation
import Testing
@testable import FarolCore

private let input = """
{"hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion", "tool_input": {"questions": [
  {"question": "Which database?", "header": "DB", "multiSelect": false,
   "options": [{"label": "Postgres", "description": "Server"}, {"label": "SQLite"}]},
  {"question": "Which checks?", "header": "Checks", "multiSelect": true, "options": [{"label": "Lint"}, {"label": "Tests"}]}
]}}
"""

@Test func readsEveryQuestion() {
    let questions = AskHook.questions(in: Data(input.utf8))
    #expect(questions?.count == 2)
    #expect(questions?[0] == AgentQuestion(
        text: "Which database?", header: "DB",
        options: [.init(label: "Postgres", detail: "Server"), .init(label: "SQLite")], multiSelect: false))
    #expect(questions?[1].multiSelect == true)
}

@Test func leavesOtherToolsAlone() {
    #expect(AskHook.questions(in: Data(#"{"tool_name": "Bash", "tool_input": {"command": "ls"}}"#.utf8)) == nil)
    #expect(AskHook.questions(in: Data()) == nil)
    #expect(AskHook.questions(in: Data("not json".utf8)) == nil)
}

@Test func refusesQuestionsItCouldMisanswer() {
    // One of two has no text, so answers keyed by text could not match what the agent asked.
    let broken = #"{"tool_input": {"questions": [{"question": "A?"}, {"options": []}]}}"#
    #expect(AskHook.questions(in: Data(broken.utf8)) == nil)
}

@Test func answersAllowTheCallWithTheAnswersAdded() throws {
    let data = try #require(AskHook.output(for: Data(input.utf8), answers: ["Which database?": "SQLite", "Which checks?": "Lint, Tests"]))
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let output = try #require(root["hookSpecificOutput"] as? [String: Any])
    #expect(output["hookEventName"] as? String == "PermissionRequest")
    let decision = try #require(output["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")
    let updated = try #require(decision["updatedInput"] as? [String: Any])
    #expect((updated["answers"] as? [String: String])?["Which database?"] == "SQLite")
    // The agent gets its own questions back along with the answers.
    #expect((updated["questions"] as? [Any])?.count == 2)
}

@Test func chatRefusesTheQuestionAndStopsTheAgent() throws {
    let data = try #require(AskHook.chatOutput())
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let decision = try #require((root["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "deny")
    #expect(decision["interrupt"] as? Bool == true)
    #expect((decision["message"] as? String)?.isEmpty == false)
}

@Test func joinsPicksWithACommaAndASpace() {
    #expect(AskHook.join(["Lint", "Tests"]) == "Lint, Tests")
    #expect(AskHook.join(["Lint"]) == "Lint")
}

@Test func replyRoundTripsThroughJSON() throws {
    let reply = AskReply(answers: ["Q": "A"])
    #expect(try JSONDecoder().decode(AskReply.self, from: JSONEncoder().encode(reply)) == reply)
    #expect(try JSONDecoder().decode(AskReply.self, from: Data("{}".utf8)).answers == nil)
    #expect(try JSONDecoder().decode(AskReply.self, from: JSONEncoder().encode(AskReply(chat: true))).chat == true)
}

@Test func installsTheAskHookWithALongTimeout() throws {
    let settings = AgentHooks.claude.install(into: [:])
    let groups = try #require((settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])
    let group = try #require(groups.first { $0["matcher"] as? String == "^AskUserQuestion$" })
    let hook = try #require((group["hooks"] as? [[String: Any]])?.first)
    #expect(hook["command"] as? String == "[ -z \"$FAROL_CLI\" ] || \"$FAROL_CLI\" ask")
    #expect(hook["timeout"] as? Int == 86_400)
}

@Test func reportsEveryPermissionRequestAsWaiting() throws {
    let settings = AgentHooks.claude.install(into: [:])
    let groups = try #require((settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])
    let group = try #require(groups.first { $0["matcher"] == nil })
    let hook = try #require((group["hooks"] as? [[String: Any]])?.first)
    #expect(hook["command"] as? String == AgentHooks.command("waiting"))
    // Without a timeout, so it never holds up Claude's own prompt.
    #expect(hook["timeout"] == nil)
}

@Test func answersOverTheSocket() throws {
    let path = "/tmp/farol-ask-\(UUID().uuidString.prefix(8))"
    let server = StatusServer(path: path, deliverOn: DispatchQueue(label: "test.delivery"))
    server.onAsk = { message, connection in
        connection.reply(AskReply(answers: [message.questions[0].text: "SQLite"]))
    }
    try server.start()
    defer { server.stop() }
    let reply = try StatusClient.ask(AskMessage(pane: "p", questions: [AgentQuestion(text: "Which?")]), to: path)
    #expect(reply == AskReply(answers: ["Which?": "SQLite"]))
}

@Test func closingWithoutAnswersGivesNone() throws {
    let path = "/tmp/farol-ask-\(UUID().uuidString.prefix(8))"
    let server = StatusServer(path: path, deliverOn: DispatchQueue(label: "test.delivery"))
    server.onAsk = { _, connection in connection.reply(AskReply()) }
    try server.start()
    defer { server.stop() }
    let reply = try StatusClient.ask(AskMessage(pane: "p", questions: [AgentQuestion(text: "Which?")]), to: path)
    #expect(reply?.answers == nil)
}
