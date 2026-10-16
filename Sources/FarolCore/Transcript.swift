import Foundation

/// The conversation an agent logs, as Claude Code or Codex writes it: one JSON record per line, appended as the session goes.
/// It is read from where it was left, so a long session costs only what was added since.
/// Only the few fields a reader needs are looked at, and a line that does not read as expected is skipped, so a change in the format loses detail, not the session.
public final class Transcript {
    public struct Message: Equatable, Sendable {
        public enum Role: String, Sendable {
            case you, agent, tool
        }

        public var id: String
        public var role: Role
        /// Your words, the agent's Markdown, or a tool's one line.
        public var text: String
        public var tool: String?
        /// A command in full, or an edit as a unified diff.
        public var detail: String?
    }

    public let url: URL
    public private(set) var messages: [Message] = []
    private var offset: UInt64 = 0
    /// The end of a line the agent was still writing.
    private var partial = Data()
    /// Where the session works, which Codex says once at the top of its log, to show paths from there.
    private var folder: String?

    public init(url: URL) {
        self.url = url
    }

    /// Reads what the agent added since the last time. True when there are new messages.
    @discardableResult
    public func refresh() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size != offset else { return false }
        // A log that got shorter was rewritten, so it is read again from the start.
        if size < offset {
            offset = 0
            partial = Data()
            messages = []
            folder = nil
        }
        try? handle.seek(toOffset: offset)
        guard let added = try? handle.readToEnd() else { return false }
        offset += UInt64(added.count)
        var data = partial + added
        let count = messages.count
        while let end = data.firstIndex(of: UInt8(ascii: "\n")) {
            messages += Self.messages(in: data[data.startIndex..<end], folder: &folder)
            data = data[data.index(after: end)...]
        }
        partial = Data(data)
        return messages.count != count
    }

    /// The messages in one line of either agent's log. Most lines are bookkeeping the agent keeps for itself, and give none.
    static func messages(in line: Data, folder: inout String?) -> [Message] {
        if line.range(of: Data(#""type":"response_item""#.utf8)) != nil || line.range(of: Data(#""type":"session_meta""#.utf8)) != nil {
            return codexMessages(in: line, folder: &folder)
        }
        return claudeMessages(in: line)
    }

    /// One line of Codex's log: a message, or a tool call, under `payload`. The top of the log names the folder.
    static func codexMessages(in line: Data, folder: inout String?) -> [Message] {
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = record["payload"] as? [String: Any] else { return [] }
        if record["type"] as? String == "session_meta" {
            folder = payload["cwd"] as? String
            return []
        }
        let id = payload["id"] as? String ?? payload["call_id"] as? String ?? UUID().uuidString
        switch payload["type"] as? String {
        case "message":
            let role = payload["role"] as? String
            let texts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            // Codex puts its own context in your turn, wrapped in tags like <environment_context>.
            guard !text.isEmpty, !text.hasPrefix("<") else { return [] }
            if role == "user" { return [Message(id: id, role: .you, text: text)] }
            if role == "assistant" { return [Message(id: id, role: .agent, text: text)] }
            return []
        case "custom_tool_call":
            return codexTool(payload["input"] as? String ?? "", in: folder, id: id).map { [$0] } ?? []
        case "function_call":
            return codexTool(payload["arguments"] as? String ?? "", name: payload["name"] as? String, in: folder, id: id).map { [$0] } ?? []
        default:
            return []
        }
    }

    /// What a Codex tool call did: an edit, from the patch it applied, or the commands it ran.
    /// Its calls are a small script, `tools.exec_command({"cmd": "…"})`, or a patch between `*** Begin Patch` and `*** End Patch`.
    static func codexTool(_ input: String, name: String? = nil, in folder: String?, id: String) -> Message? {
        if let patch = patch(in: input) {
            let files = patch.split(separator: "\n").compactMap { $0.firstMatch(of: #/^\*\*\* (?:Update|Add|Delete) File: (.+)$/#).map { String($0.1) } }
            let diff = patch.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                if let file = line.firstMatch(of: #/^\*\*\* (?:Update|Add|Delete) File: (.+)$/#) { return "@@ \(relative(String(file.1), to: folder))" }
                return line.hasPrefix("*** ") ? "" : String(line)
            }.filter { !$0.isEmpty }.joined(separator: "\n")
            let text = files.map { relative($0, to: folder) }.joined(separator: ", ")
            return Message(id: id, role: .tool, text: text.isEmpty ? "A patch" : text, tool: "Edit", detail: limit(diff + "\n"))
        }
        let commands = input.matches(of: #/"?cmd"?\s*:\s*"((?:[^"\\]|\\.)*)"/#).compactMap { unescaped(String($0.1)) }
        if let first = commands.first {
            let line = commands.count > 1 ? "\(first.split(separator: "\n").first ?? "") and \(commands.count - 1) more" : String(first.split(separator: "\n").first ?? "")
            return Message(id: id, role: .tool, text: line, tool: "Bash", detail: commands.joined(separator: "\n"))
        }
        // A call that only waits on another, or keeps Codex's own plan, says nothing worth a line.
        if let name, ["wait", "update_plan"].contains(name) { return nil }
        return name.map { Message(id: id, role: .tool, text: $0, tool: $0) }
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

    /// One line of Claude Code's log.
    static func claudeMessages(in line: Data) -> [Message] {
        // Most of a long log is requests and their payloads. Only the two kinds of record that hold the conversation are parsed.
        guard line.range(of: Data(#""type":"user""#.utf8)) != nil || line.range(of: Data(#""type":"assistant""#.utf8)) != nil,
              let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = record["type"] as? String, type == "user" || type == "assistant",
              record["isMeta"] as? Bool != true, record["isSidechain"] as? Bool != true,
              let message = record["message"] as? [String: Any] else { return [] }
        let id = record["uuid"] as? String ?? UUID().uuidString
        let folder = record["cwd"] as? String
        let blocks: [[String: Any]]
        if let text = message["content"] as? String {
            blocks = [["type": "text", "text": text]]
        } else {
            blocks = message["content"] as? [[String: Any]] ?? []
        }
        return blocks.enumerated().compactMap { place, block in
            let id = "\(id).\(place)"
            switch (type, block["type"] as? String) {
            case ("user", "text"):
                // What Claude Code adds to a turn by itself, like a command it ran or a notice, comes wrapped in a tag.
                guard let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                      !text.hasPrefix("<") else { return nil }
                return Message(id: id, role: .you, text: text)
            case ("user", "image"):
                return Message(id: id, role: .you, text: "An image")
            case ("assistant", "text"):
                guard let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return Message(id: id, role: .agent, text: text)
            case ("assistant", "tool_use"):
                guard let name = block["name"] as? String else { return nil }
                return tool(name, block["input"] as? [String: Any] ?? [:], in: folder, id: id)
            default:
                // Thinking, and what tools gave back, which the agent's own answer says in fewer words.
                return nil
            }
        }
    }

    /// A tool the agent ran, in one line, with what it did in full where that is worth reading.
    static func tool(_ name: String, _ input: [String: Any], in folder: String?, id: String) -> Message {
        func string(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let path = string("file_path").map { relative($0, to: folder) }
        switch name {
        case "Bash":
            let command = string("command") ?? ""
            let line = string("description") ?? command.split(separator: "\n").first.map(String.init) ?? "A command"
            return Message(id: id, role: .tool, text: line, tool: name, detail: command)
        case "Edit", "MultiEdit":
            let edits = (input["edits"] as? [[String: Any]]) ?? [input]
            let diff = edits.map { unified(old: $0["old_string"] as? String ?? "", new: $0["new_string"] as? String ?? "") }.joined()
            return Message(id: id, role: .tool, text: path ?? "A file", tool: name, detail: limit(diff))
        case "Write":
            return Message(id: id, role: .tool, text: path ?? "A file", tool: name, detail: limit(unified(old: "", new: string("content") ?? "")))
        case "Read":
            return Message(id: id, role: .tool, text: path ?? "A file", tool: name)
        case "Grep", "Glob":
            return Message(id: id, role: .tool, text: string("pattern") ?? name, tool: name)
        case "WebSearch":
            return Message(id: id, role: .tool, text: string("query") ?? name, tool: name)
        case "WebFetch":
            return Message(id: id, role: .tool, text: string("url") ?? name, tool: name)
        case "Task", "Agent":
            return Message(id: id, role: .tool, text: string("description") ?? name, tool: name)
        case "TodoWrite":
            return Message(id: id, role: .tool, text: "Updated the to-do list", tool: name)
        default:
            return Message(id: id, role: .tool, text: string("skill") ?? string("description") ?? name, tool: name)
        }
    }

    /// An edit as a diff with one hunk: the old lines removed, the new ones added. Context and line numbers are not in the log.
    static func unified(old: String, new: String) -> String {
        let lines = { (text: String, sign: String) in text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map { sign + $0 } }
        return (["@@"] + lines(old, "-") + lines(new, "+")).joined(separator: "\n") + "\n"
    }

    private static func relative(_ path: String, to folder: String?) -> String {
        guard let folder, path.hasPrefix(folder + "/") else { return path }
        return String(path.dropFirst(folder.count + 1))
    }

    /// Long enough for any edit worth reading on a phone, short enough to travel in one message.
    private static func limit(_ text: String, to bytes: Int = 20_000) -> String {
        guard text.utf8.count > bytes else { return text }
        return String(decoding: text.utf8.prefix(bytes), as: UTF8.self) + "\n… cut short, open it on the Mac for the rest"
    }
}
