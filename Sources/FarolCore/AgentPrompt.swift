import Foundation

/// What a waiting agent asks, taken from the JSON a hook receives on stdin.
public struct AgentPrompt: Codable, Equatable, Sendable {
    public var text: String
    /// The choices the agent offers, empty for a permission prompt.
    public var options: [String]

    public init(text: String, options: [String] = []) {
        self.text = text
        self.options = options
    }

    /// A question with options, the tool a permission is asked for, or a prompt's message. Nil when the input has none.
    /// Hooks must never fail the agent, so anything unexpected gives nil instead of an error.
    public init?(hookInput data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let input = root["tool_input"] as? [String: Any]
        if let questions = input?["questions"] as? [[String: Any]],
           let first = questions.first, let text = Self.clean(first["question"]) {
            let options = (first["options"] as? [[String: Any]] ?? []).compactMap { Self.clean($0["label"]) }
            // Only the first question is shown. The rest are answered in the terminal.
            let more = questions.count - 1
            self.init(text: more > 0 ? "\(text) (+\(more) more)" : text, options: options)
        } else if let tool = Self.clean(root["tool_name"]) {
            self.init(text: Self.describe(tool, input: input))
        } else if let message = Self.clean(root["message"]) {
            self.init(text: message)
        } else {
            return nil
        }
    }

    /// The text and options on one line, cut to fit a notification.
    public func summary(limit: Int = 180) -> String {
        let line = options.isEmpty ? text : text + " " + options.joined(separator: " · ")
        return line.count <= limit ? line : String(line.prefix(limit - 1)) + "…"
    }

    /// The tool and what it would touch, like "Bash: rm -rf build". The first line only, since a notification is small.
    private static func describe(_ tool: String, input: [String: Any]?) -> String {
        let keys = ["command", "file_path", "path", "url", "pattern", "query"]
        guard let detail = keys.lazy.compactMap({ clean(input?[$0]) }).first else { return tool }
        let lines = detail.split(whereSeparator: \.isNewline)
        return "\(tool): \(lines.first ?? "")" + (lines.count > 1 ? "…" : "")
    }

    private static func clean(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
