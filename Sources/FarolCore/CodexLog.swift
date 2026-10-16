import Foundation

/// Codex's log: a message or a tool call under each line's `payload`, one after the other. The top of the log names the folder.
final class CodexLog: AgentLog {
    private(set) var messages: [Transcript.Message] = []
    /// Where the session works, to show paths from there.
    private var folder: String?

    func read(_ line: Data) -> Bool {
        // Most lines are Codex's own bookkeeping, like token counts, and are not parsed.
        guard line.range(of: Data(#""type":"response_item""#.utf8)) != nil || line.range(of: Data(#""type":"session_meta""#.utf8)) != nil,
              let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = record["payload"] as? [String: Any] else { return false }
        if record["type"] as? String == "session_meta" {
            folder = payload["cwd"] as? String
            return false
        }
        // Ids only need to tell messages apart, and a message without one is numbered after the others.
        let id = payload["id"] as? String ?? payload["call_id"] as? String ?? "codex.\(messages.count)"
        let message: Transcript.Message?
        switch payload["type"] as? String {
        case "message":
            let role = payload["role"] as? String
            let content = payload["content"] as? [[String: Any]] ?? []
            // Codex puts its own context in your turn, and the images you paste, wrapped in tags like <environment_context>.
            let texts = content.compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.hasPrefix("<") }
            var text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, content.contains(where: { $0["type"] as? String == "input_image" }) { text = "An image" }
            guard !text.isEmpty else { return false }
            message = switch role {
            case "user": Transcript.Message(id: id, role: .you, text: text)
            case "assistant": Transcript.Message(id: id, role: .agent, text: text)
            default: nil
            }
        case "custom_tool_call":
            message = Self.tool(payload["input"] as? String ?? "", in: folder, id: id)
        case "function_call":
            message = Self.tool(payload["arguments"] as? String ?? "", name: payload["name"] as? String, in: folder, id: id)
        default:
            message = nil
        }
        guard let message else { return false }
        messages.append(message)
        return true
    }

    /// What a Codex tool call did: an edit, from the patch it applied, or the commands it ran.
    /// Its calls are a small script, `tools.exec_command({"cmd": "…"})`, or a patch between `*** Begin Patch` and `*** End Patch`.
    static func tool(_ input: String, name: String? = nil, in folder: String?, id: String) -> Transcript.Message? {
        if let patch = patch(in: input) {
            let files = patch.split(separator: "\n").compactMap { $0.firstMatch(of: #/^\*\*\* (?:Update|Add|Delete) File: (.+)$/#).map { String($0.1) } }
            let diff = patch.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                if let file = line.firstMatch(of: #/^\*\*\* (?:Update|Add|Delete) File: (.+)$/#) { return "@@ \(Transcript.relative(String(file.1), to: folder))" }
                return line.hasPrefix("*** ") ? "" : String(line)
            }.filter { !$0.isEmpty }.joined(separator: "\n")
            let text = files.map { Transcript.relative($0, to: folder) }.joined(separator: ", ")
            return Transcript.Message(id: id, role: .tool, text: text.isEmpty ? "A patch" : text, tool: "Edit", detail: Transcript.limit(diff + "\n"))
        }
        let commands = input.matches(of: #/"?cmd"?\s*:\s*"((?:[^"\\]|\\.)*)"/#).compactMap { unescaped(String($0.1)) }
        if let first = commands.first {
            let line = commands.count > 1 ? "\(first.split(separator: "\n").first ?? "") and \(commands.count - 1) more" : String(first.split(separator: "\n").first ?? "")
            return Transcript.Message(id: id, role: .tool, text: line, tool: "Bash", detail: commands.joined(separator: "\n"))
        }
        // A call that only waits on another, or keeps Codex's own plan, says nothing worth a line.
        if let name, ["wait", "update_plan"].contains(name) { return nil }
        return name.map { Transcript.Message(id: id, role: .tool, text: $0, tool: $0) }
    }

    /// The patch in a tool call, as written between its markers, with the escapes of the string it came in undone.
    private static func patch(in input: String) -> String? {
        guard let start = input.range(of: "*** Begin Patch"), let end = input.range(of: "*** End Patch", range: start.upperBound..<input.endIndex) else { return nil }
        let raw = String(input[start.lowerBound..<end.upperBound])
        return raw.contains("\\n") ? unescaped(raw) : raw
    }

    /// A JSON string's escapes undone, as `\n` in a command or a patch.
    private static func unescaped(_ text: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data("\"\(text)\"".utf8), options: .fragmentsAllowed)) as? String ?? text
    }
}
