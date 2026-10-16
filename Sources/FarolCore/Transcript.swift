import Foundation

/// The conversation an agent logs, as Claude Code writes it: one JSON record per line, appended as the session goes.
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
        }
        try? handle.seek(toOffset: offset)
        guard let added = try? handle.readToEnd() else { return false }
        offset += UInt64(added.count)
        var data = partial + added
        let count = messages.count
        while let end = data.firstIndex(of: UInt8(ascii: "\n")) {
            messages += Self.messages(in: data[data.startIndex..<end])
            data = data[data.index(after: end)...]
        }
        partial = Data(data)
        return messages.count != count
    }

    /// The messages in one line of the log. Most lines are bookkeeping the agent keeps for itself, and give none.
    static func messages(in line: Data) -> [Message] {
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
