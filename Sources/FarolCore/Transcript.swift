import Foundation

/// The conversation an agent logs, as Claude Code or Codex writes it: one JSON record per line, appended as the session goes.
/// It is read from where it was left, a megabyte at a time, so a long session costs only what was added since and never sits whole in memory.
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
        /// How a tool call ended, once its result is in, when not as asked.
        public var outcome: Outcome?

        public enum Outcome: String, Sendable {
            /// You said no when it asked, or interrupted it.
            case stopped
            case failed
        }
    }

    public let url: URL
    public var messages: [Message] { log?.messages ?? [] }
    /// The messages the last refresh changed in place, by id, like a tool whose result came after it.
    public private(set) var revised: Set<String> = []
    /// Which agent wrote it, known from its first line.
    private var log: AgentLog?
    private var offset: UInt64 = 0
    /// The end of a line the agent was still writing.
    private var partial = Data()
    /// In a line too long to keep, until it ends.
    private var skipping = false

    public init(url: URL) {
        self.url = url
    }

    /// Reads what the agent added since the last time. True when the messages changed.
    @discardableResult
    public func refresh() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size != offset else { return false }
        // A log that got shorter was rewritten, so it is read again from the start.
        if size < offset {
            offset = 0
            partial = Data()
            skipping = false
            log = nil
        }
        try? handle.seek(toOffset: offset)
        revised = []
        var changed = false
        // Foundation leaves the chunks it reads and the objects JSONSerialization makes to an autorelease pool, which would otherwise hold a whole log's worth until the read ends.
        while let more = autoreleasepool(invoking: { (try? handle.read(upToCount: 1 << 20)).flatMap { $0.isEmpty ? nil : take($0) } }) {
            if more { changed = true }
        }
        if let log {
            revised = log.revised
            log.revised = []
        }
        return changed
    }

    /// Reads the lines a chunk ends. True when the messages changed.
    private func take(_ chunk: Data) -> Bool {
        offset += UInt64(chunk.count)
        var changed = false
        // Only the new bytes are searched for the end of a line, since one line can hold megabytes of pasted images.
        var searched = partial.endIndex
        partial.append(chunk)
        var start = partial.startIndex
        while let end = partial[searched...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = partial[start..<end]
            start = partial.index(after: end)
            searched = start
            if skipping {
                skipping = false
                continue
            }
            guard !line.isEmpty else { continue }
            if log == nil { log = Self.isCodex(line) ? CodexLog() : ClaudeLog() }
            if log?.read(line) == true { changed = true }
        }
        partial.removeSubrange(..<start)
        // A line of many megabytes is pasted images or a compacted history, nothing to show on a phone, so it is not held.
        if partial.count > 8 << 20 {
            partial = Data()
            skipping = true
        }
        return changed
    }

    /// Codex starts its log with a record of the session. Claude Code starts with anything else.
    private static func isCodex(_ line: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["type"] as? String == "session_meta"
    }

    /// An edit as a diff with one hunk: the old lines removed, the new ones added. Context and line numbers are not in the log.
    static func unified(old: String, new: String) -> String {
        let lines = { (text: String, sign: String) in text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map { sign + $0 } }
        return (["@@"] + lines(old, "-") + lines(new, "+")).joined(separator: "\n") + "\n"
    }

    static func relative(_ path: String, to folder: String?) -> String {
        guard let folder, path.hasPrefix(folder + "/") else { return path }
        return String(path.dropFirst(folder.count + 1))
    }

    /// A question tool's call, as one row: the first question as its line, and every question with its answers as its detail.
    /// Claude Code writes `question` and options with a `label`, Codex `question` or `title` and options as labels or plain words.
    static func question(_ questions: [[String: Any]], id: String) -> Message? {
        func text(_ question: [String: Any]) -> String? {
            [question["question"], question["title"], question["text"]].lazy.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        }
        func answers(_ question: [String: Any]) -> [String] {
            (question["options"] as? [Any] ?? []).compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["label"] as? String) }
        }
        guard let first = questions.first.flatMap(text) else { return nil }
        let detail = questions.compactMap { question in
            text(question).map { ([$0] + answers(question).map { "· \($0)" }).joined(separator: "\n") }
        }.joined(separator: "\n\n")
        return Message(id: id, role: .tool, text: first, tool: "Question", detail: detail == first ? nil : detail)
    }

    /// Long enough for any edit worth reading on a phone, short enough to travel in one message.
    /// True when the last turn in an agent's log is you stopping it, after `since`. Only Claude Code's say so.
    public static func stopped(log: String, since: Date) -> Bool {
        ClaudeLog.stopped(log: log, since: since)
    }

    static func limit(_ text: String, to bytes: Int = 20_000) -> String {
        guard text.utf8.count > bytes else { return text }
        return String(decoding: text.utf8.prefix(bytes), as: UTF8.self) + "\n… cut short, open it on the Mac for the rest"
    }
}

/// One agent's way of logging, read a line at a time.
protocol AgentLog: AnyObject {
    var messages: [Transcript.Message] { get }
    /// Messages read before that a later line changed, by id, since the transcript last took them.
    var revised: Set<String> { get set }
    /// True when the line changed the messages.
    func read(_ line: Data) -> Bool
}
