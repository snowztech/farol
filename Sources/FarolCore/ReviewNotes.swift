import Foundation

/// A note you leave on lines of your own changes, for the agent that made them.
/// It keeps the text of its lines, so it can find them again after the agent edits the file around them.
public struct ReviewNote: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var path: String
    /// The first and last line, numbered in the new file, or in the old one when every line is removed.
    public var line: Int
    public var end: Int
    public var old: Bool
    public var quote: [String]
    public var text: String
    /// When it went to the agent. Kept until you resolve it, so you can check it was dealt with.
    public var sentAt: Date?
    public var sent: Bool { sentAt != nil }
    /// Its lines are no longer in the diff, so it shows apart, without a line.
    public var lost = false

    public init(path: String, line: Int, end: Int, old: Bool, quote: [String], text: String) {
        self.path = path
        self.line = line
        self.end = end
        self.old = old
        self.quote = quote
        self.text = text
    }
}

public enum ReviewNotes {
    /// One thing for the agent to address, from your notes or from a reviewer's comments on a request.
    public struct Item: Equatable, Sendable {
        public var path: String
        public var line: Int
        public var end: Int
        public var old: Bool
        public var quote: [String]
        public var text: String
        /// Who wrote it, for a reviewer's comment. Nil for your own note.
        public var author: String?

        public init(path: String, line: Int, end: Int, old: Bool, quote: [String], text: String, author: String? = nil) {
            self.path = path
            self.line = line
            self.end = end
            self.old = old
            self.quote = quote
            self.text = text
            self.author = author
        }

        public init(_ note: ReviewNote) {
            self.init(path: note.path, line: note.line, end: note.end, old: note.old, quote: note.quote, text: note.text)
        }
    }

    public static let yourNotes = "Review notes on your changes. Address each one, then say what you changed."
    public static let reviewerComments = "Review comments on the pull request. Address each one, then say what you changed."

    /// One numbered prompt. Each item says where, quotes the lines so the agent finds them even once numbers move, then what to do.
    public static func prompt(_ items: [Item], header: String = yourNotes, also: String? = nil) -> String {
        var parts = [header]
        for (index, item) in items.enumerated() {
            let lines = item.line == item.end ? "\(item.line)" : "\(item.line)-\(item.end)"
            let place = item.old ? "\(item.path), removed \(item.line == item.end ? "line" : "lines") \(lines)" : "\(item.path):\(lines)"
            var block = ["\(index + 1). \(place)"]
            // Blank lines at either end say nothing to the agent.
            let quote = item.quote.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                .reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.reversed()
            block += quote.prefix(12).map { "   > \($0)" }
            if quote.count > 12 { block.append("   > …") }
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "\n   ")
            block.append("   " + (item.author.map { "\($0): " } ?? "") + text)
            parts.append(block.joined(separator: "\n"))
        }
        if let also = also?.trimmingCharacters(in: .whitespacesAndNewlines), !also.isEmpty { parts.append("Also: \(also)") }
        return parts.joined(separator: "\n\n")
    }

    /// The diff's lines of a file in order, each with its number in the new file and in the old one.
    private struct Row: Equatable {
        let text: String
        let new: Int?
        let old: Int?
    }

    private static func rows(_ file: Diff.File) -> [Row] {
        file.hunks.flatMap { hunk -> [Row] in
            var old = hunk.oldStart
            return hunk.lines.map { line in
                defer { if line.kind != .added { old += 1 } }
                return Row(text: line.text, new: line.kind == .removed ? nil : line.number, old: line.kind == .added ? nil : old)
            }
        }
    }

    private static func index(of line: Int, old: Bool, in rows: [Row]) -> Int? {
        rows.firstIndex { old ? $0.old == line && $0.new == nil : $0.new == line }
    }

    /// The text of lines `line` through `end`, with any removed lines between them. Nil when the diff doesn't show them.
    public static func quote(in file: Diff.File, line: Int, end: Int, old: Bool) -> [String]? {
        let rows = rows(file)
        guard let first = index(of: line, old: old, in: rows), let last = index(of: end, old: old, in: rows), first <= last else { return nil }
        return rows[first...last].map(\.text)
    }

    /// The note on the lines that still read as it quotes, nearest where it was. Lost when no lines do.
    public static func anchor(_ note: ReviewNote, in files: [Diff.File]) -> ReviewNote {
        var note = note
        guard let file = files.first(where: { $0.path == note.path }), !note.quote.isEmpty else {
            note.lost = true
            return note
        }
        let rows = rows(file)
        let was = index(of: note.line, old: note.old, in: rows)
        if let was, rows.count >= was + note.quote.count, rows[was..<(was + note.quote.count)].map(\.text) == note.quote {
            note.lost = false
            return note
        }
        let starts = rows.indices.filter { start in
            start + note.quote.count <= rows.count && rows[start..<(start + note.quote.count)].map(\.text) == note.quote
        }
        guard let start = starts.min(by: { abs($0 - (was ?? $0)) < abs($1 - (was ?? $1)) }) else {
            note.lost = true
            return note
        }
        let span = rows[start..<(start + note.quote.count)]
        let numbers = span.compactMap(\.new)
        if let first = numbers.first, let last = numbers.last {
            (note.line, note.end, note.old) = (first, last, false)
        } else if let first = span.first?.old, let last = span.last?.old {
            (note.line, note.end, note.old) = (first, last, true)
        }
        note.lost = false
        return note
    }
}
