import Foundation

/// One question an agent asks through its question tool, with the choices it offers.
public struct AgentQuestion: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public var label: String
        public var detail: String

        public init(label: String, detail: String = "") {
            self.label = label
            self.detail = detail
        }
    }

    public var text: String
    public var header: String
    public var options: [Option]
    public var multiSelect: Bool

    public init(text: String, header: String = "", options: [Option] = [], multiSelect: Bool = false) {
        self.text = text
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// A question the agent is blocked on. `farol ask` sends it and keeps the connection open for the answer.
public struct AskMessage: Codable, Equatable, Sendable {
    public var pane: String
    public var questions: [AgentQuestion]

    public init(pane: String, questions: [AgentQuestion]) {
        self.pane = pane
        self.questions = questions
    }
}

/// Farol's answer to an ask. No answers means "answer in the terminal", and the agent asks there as usual.
public struct AskReply: Codable, Equatable, Sendable {
    /// The chosen label (or typed text) for each question, keyed by the question's text.
    public var answers: [String: String]?
    /// Turn the question down so the user can talk it over with the agent.
    public var chat: Bool?

    public init(answers: [String: String]? = nil, chat: Bool? = nil) {
        self.answers = answers
        self.chat = chat
    }
}

/// The hook side of a question: reading it from the agent's JSON, and writing the answer back in the agent's format.
public enum AskHook {
    /// The questions of a question tool call. Nil for anything else, so the agent asks in the terminal.
    public static func questions(in data: Data) -> [AgentQuestion]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = (root["tool_input"] as? [String: Any])?["questions"] as? [[String: Any]] else { return nil }
        let questions = raw.compactMap { item -> AgentQuestion? in
            guard let text = clean(item["question"]) else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentQuestion.Option? in
                clean(option["label"]).map { AgentQuestion.Option(label: $0, detail: clean(option["description"]) ?? "") }
            }
            return AgentQuestion(
                text: text, header: clean(item["header"]) ?? "", options: options, multiSelect: item["multiSelect"] as? Bool ?? false)
        }
        // A question dropped for lacking text would leave the others answered against the wrong tool input.
        return questions.count == raw.count && !questions.isEmpty ? questions : nil
    }

    /// What the hook prints: allow the tool call, with the answers added to its input as the agent does itself.
    public static func output(for input: Data, answers: [String: String]) -> Data? {
        guard let root = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              var toolInput = root["tool_input"] as? [String: Any] else { return nil }
        toolInput["answers"] = answers
        let output: [String: Any] = [
            "continue": true,
            "suppressOutput": true,
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow", "updatedInput": toolInput],
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// What the hook prints to refuse the question and stop the agent, like the question dialog's own "Chat about this".
    public static func chatOutput() -> Data? {
        let output: [String: Any] = [
            "continue": true,
            "suppressOutput": true,
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "deny",
                    "message": "The user didn't answer this question. They want to chat about it first.",
                    "interrupt": true,
                ],
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Several picks in a multiple choice join with a comma, as the agent's own question tool does.
    public static func join(_ labels: [String]) -> String { labels.joined(separator: ", ") }

    private static func clean(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
