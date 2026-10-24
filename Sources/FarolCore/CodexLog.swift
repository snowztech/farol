import Foundation

/// Codex's log: a message or a tool call under each line's `payload`, one after the other. The top of the log names the folder.
final class CodexLog: AgentLog {
    private(set) var messages: [Transcript.Message] = []
    var revised: Set<String> = []
    /// Where the session works, to show paths from there.
    private var folder: String?
    /// Each tool call's place in the messages, by the id its output names it by.
    private var calls: [String: Int] = [:]

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
        case "function_call_output", "custom_tool_call_output":
            return ended(payload)
        default:
            message = nil
        }
        guard let message else { return false }
        if message.role == .tool, let call = payload["call_id"] as? String { calls[call] = messages.count }
        messages.append(message)
        return true
    }

    /// A tool call's output, which says whether you stopped it or a command it ran failed.
    private func ended(_ payload: [String: Any]) -> Bool {
        guard let call = payload["call_id"] as? String, let place = calls[call] else { return false }
        let output = payload["output"] as? String ?? ""
        guard let outcome = Self.outcome(of: output) else { return false }
        messages[place].outcome = outcome
        revised.insert(messages[place].id)
        return true
    }

    /// Codex writes "aborted by user" for a call you said no to or interrupted, and each command's exit code in what it ran.
    static func outcome(of output: String) -> Transcript.Message.Outcome? {
        if output.hasPrefix("aborted by user") { return .stopped }
        // Escaped once at most: a command's own output that quotes an exit code is escaped deeper.
        let codes = output.matches(of: #/exit_code\\?"\s*:\s*(-?\d+)/#).compactMap { Int($0.1) }
        return codes.contains { $0 != 0 } ? .failed : nil
    }

    /// What a Codex tool call did: an edit, from the patch it applied, or the commands it ran.
    /// Its calls are a small script, `tools.exec_command({"cmd": "…"})`, or a patch between `*** Begin Patch` and `*** End Patch`.
    static func tool(_ input: String, name: String? = nil, in folder: String?, id: String) -> Transcript.Message? {
        // Codex asks with request_user_input, and while it works with request_user_input_async.
        if let name, name.hasPrefix("request_user_input"),
           let arguments = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any],
           let question = Transcript.question(arguments["questions"] as? [[String: Any]] ?? [], id: id) {
            return question
        }
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
