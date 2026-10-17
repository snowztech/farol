import Foundation

/// Claude Code's log. Each record names the one it follows with `parentUuid`, so the conversation is a tree:
/// tools run side by side each hang off the call that started them, and a prompt you rewound to sits beside the one it replaced.
/// Messages are shown in the order they were written, without what a rewind left behind.
final class ClaudeLog: AgentLog {
    /// How Claude Code writes, as your turn, that you stopped it.
    static let stopMark = "[Request interrupted by user"

    /// The records that gave messages, in the order they were written.
    private var records: [(id: String, messages: [Transcript.Message])] = []
    private var children: [String: [String]] = [:]
    /// The prompt written last after each record. A rewind writes a new one after the same record.
    private var prompts: [String: String] = [:]
    /// Prompts a rewind replaced, and all that followed from them.
    private var abandoned: Set<String> = []
    private var shown: [Transcript.Message]?

    var messages: [Transcript.Message] {
        if let shown { return shown }
        let messages = records.filter { !abandoned.contains($0.id) }.flatMap(\.messages)
        shown = messages
        return messages
    }

    func read(_ line: Data) -> Bool {
        // Only records in the conversation name a parent. The rest, like settings and file snapshots, are not parsed.
        guard line.range(of: Data(#""parentUuid""#.utf8)) != nil,
              let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              record["isSidechain"] as? Bool != true, let id = record["uuid"] as? String else { return false }
        let parent = record["parentUuid"] as? String
        if let parent {
            children[parent, default: []].append(id)
            if abandoned.contains(parent) { abandoned.insert(id) }
        }
        let messages = Self.messages(in: record, id: id)
        var changed = !messages.isEmpty
        if let parent, messages.contains(where: { $0.role == .you }) {
            if let earlier = prompts[parent] {
                abandon(earlier)
                changed = true
            }
            prompts[parent] = id
        }
        if !messages.isEmpty { records.append((id, messages)) }
        if changed { shown = nil }
        return changed
    }

    private func abandon(_ id: String) {
        var left = [id]
        while let next = left.popLast() {
            guard abandoned.insert(next).inserted else { continue }
            left += children[next] ?? []
        }
    }

    /// The messages in one record: your prompt, or the agent's answer and the tools it called.
    static func messages(in record: [String: Any], id: String) -> [Transcript.Message] {
        // Claude Code writes notes to itself as your turn, and its summary of a compacted conversation, and marks them.
        guard let type = record["type"] as? String, type == "user" || type == "assistant",
              record["isMeta"] as? Bool != true, record["isCompactSummary"] as? Bool != true,
              let message = record["message"] as? [String: Any] else { return [] }
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
                // A stop comes in brackets, and the pane going idle says it already.
                guard let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                      !text.hasPrefix("<"), !text.hasPrefix(stopMark) else { return nil }
                return Transcript.Message(id: id, role: .you, text: text)
            case ("user", "image"):
                return Transcript.Message(id: id, role: .you, text: "An image")
            case ("assistant", "text"):
                guard let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return Transcript.Message(id: id, role: .agent, text: text)
            case ("assistant", "tool_use"):
                guard let name = block["name"] as? String else { return nil }
                return Self.tool(name, block["input"] as? [String: Any] ?? [:], in: folder, id: id)
            default:
                // Thinking, and what tools gave back, which the agent's own answer says in fewer words.
                return nil
            }
        }
    }

    /// A tool the agent ran, in one line, with what it did in full where that is worth reading.
    static func tool(_ name: String, _ input: [String: Any], in folder: String?, id: String) -> Transcript.Message {
        func string(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let path = string("file_path").map { Transcript.relative($0, to: folder) }
        switch name {
        case "Bash":
            let command = string("command") ?? ""
            let line = string("description") ?? command.split(separator: "\n").first.map(String.init) ?? "A command"
            return Transcript.Message(id: id, role: .tool, text: line, tool: name, detail: command)
        case "Edit", "MultiEdit":
            let edits = (input["edits"] as? [[String: Any]]) ?? [input]
            let diff = edits.map { Transcript.unified(old: $0["old_string"] as? String ?? "", new: $0["new_string"] as? String ?? "") }.joined()
            return Transcript.Message(id: id, role: .tool, text: path ?? "A file", tool: name, detail: Transcript.limit(diff))
        case "Write":
            return Transcript.Message(id: id, role: .tool, text: path ?? "A file", tool: name, detail: Transcript.limit(Transcript.unified(old: "", new: string("content") ?? "")))
        case "Read":
            return Transcript.Message(id: id, role: .tool, text: path ?? "A file", tool: name)
        case "Grep", "Glob":
            return Transcript.Message(id: id, role: .tool, text: string("pattern") ?? name, tool: name)
        case "WebSearch":
            return Transcript.Message(id: id, role: .tool, text: string("query") ?? name, tool: name)
        case "WebFetch":
            return Transcript.Message(id: id, role: .tool, text: string("url") ?? name, tool: name)
        case "Task", "Agent":
            return Transcript.Message(id: id, role: .tool, text: string("description") ?? name, tool: name)
        case "TodoWrite":
            return Transcript.Message(id: id, role: .tool, text: "Updated the to-do list", tool: name)
        default:
            return Transcript.Message(id: id, role: .tool, text: string("skill") ?? string("description") ?? name, tool: name)
        }
    }

    /// True when the last turn in a Claude Code log is you stopping it, after `since`.
    /// Claude Code runs no hook when you stop it, so this is how Farol learns the agent no longer works.
    static func stopped(log: String, since: Date) -> Bool {
        guard let file = FileHandle(forReadingAtPath: log) else { return false }
        defer { try? file.close() }
        // What comes after the mark, like the permission mode, is short.
        guard let end = try? file.seekToEnd() else { return false }
        try? file.seek(toOffset: end > 16 << 10 ? end - 16 << 10 : 0)
        guard let tail = try? file.readToEnd() else { return false }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            // The first line may be cut in two, and is then skipped like any other line that is not a turn.
            guard line.range(of: Data(#""parentUuid""#.utf8)) != nil,
                  let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  record["isSidechain"] as? Bool != true, let type = record["type"] as? String, type == "user" || type == "assistant" else { continue }
            guard type == "user", let written = (record["timestamp"] as? String).flatMap(dates.date(from:)), written > since,
                  let blocks = (record["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return false }
            return blocks.contains { $0["type"] as? String == "text" && ($0["text"] as? String)?.hasPrefix(stopMark) == true }
        }
        return false
    }
}
