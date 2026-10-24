import Foundation

/// Pi's log: a `session` line that names the folder, then a `message` line for each of your messages, its answers and its tools' results.
/// The messages form a tree when you go back with /tree. Read in the order they were written, a branch you left shows before the one you took.
final class PiLog: AgentLog {
    private(set) var messages: [Transcript.Message] = []
    var revised: Set<String> = []
    private var folder: String?
    /// Each tool call's place in the messages, by its id.
    private var calls: [String: Int] = [:]

    func read(_ line: Data) -> Bool {
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return false }
        if record["type"] as? String == "session" {
            folder = record["cwd"] as? String
            return false
        }
        guard record["type"] as? String == "message", let message = record["message"] as? [String: Any],
              let id = record["id"] as? String else { return false }
        let content = message["content"] as? [[String: Any]] ?? []
        switch message["role"] as? String {
        case "user":
            var text = Self.text(in: content)
            if text.isEmpty, content.contains(where: { $0["type"] as? String == "image" }) { text = "An image" }
            return add(Transcript.Message(id: id, role: .you, text: text))
        case "assistant":
            var changed = add(Transcript.Message(id: id, role: .agent, text: Self.text(in: content)))
            for (index, part) in content.enumerated() where part["type"] as? String == "toolCall" {
                let call = part["id"] as? String ?? "\(id).\(index)"
                calls[call] = messages.count
                messages.append(Self.tool(part["name"] as? String ?? "tool", part["arguments"] as? [String: Any] ?? [:], in: folder, id: call))
                changed = true
            }
            return changed
        case "toolResult":
            guard message["isError"] as? Bool == true, let call = message["toolCallId"] as? String, let place = calls[call] else { return false }
            messages[place].outcome = .failed
            revised.insert(messages[place].id)
            return true
        default:
            return false
        }
    }

    private func add(_ message: Transcript.Message) -> Bool {
        guard !message.text.isEmpty else { return false }
        messages.append(message)
        return true
    }

    private static func text(in content: [[String: Any]]) -> String {
        content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pi's tools are Claude Code's under other names and keys, so they show the same way.
    static func tool(_ name: String, _ arguments: [String: Any], in folder: String?, id: String) -> Transcript.Message {
        let path = arguments["path"] as? String
        return switch name {
        case "bash": ClaudeLog.tool("Bash", ["command": arguments["command"] as? String ?? ""], in: folder, id: id)
        case "read": ClaudeLog.tool("Read", ["file_path": path ?? ""], in: folder, id: id)
        case "write": ClaudeLog.tool("Write", ["file_path": path ?? "", "content": arguments["content"] as? String ?? ""], in: folder, id: id)
        case "edit":
            ClaudeLog.tool("Edit", ["file_path": path ?? "", "edits": (arguments["edits"] as? [[String: Any]] ?? [arguments]).map {
                ["old_string": $0["oldText"] as? String ?? "", "new_string": $0["newText"] as? String ?? ""]
            }], in: folder, id: id)
        case "grep": ClaudeLog.tool("Grep", ["pattern": arguments["pattern"] as? String ?? ""], in: folder, id: id)
        case "find": ClaudeLog.tool("Glob", ["pattern": arguments["pattern"] as? String ?? ""], in: folder, id: id)
        case "ls": Transcript.Message(id: id, role: .tool, text: path.map { Transcript.relative($0, to: folder) } ?? ".", tool: "Glob")
        // Pi asks you through tools its extensions add, by any name, in Claude Code's shape.
        default: (arguments["questions"] as? [[String: Any]]).flatMap { Transcript.question($0, id: id) } ?? ClaudeLog.tool(name, arguments, in: folder, id: id)
        }
    }
}
