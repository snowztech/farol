import Foundation

/// Turns on Codex's terminal notifications, since its hooks run in a background process that doesn't know their terminal.
/// The file is edited line by line so comments survive, and turning off removes only the lines Farol marked.
public enum CodexNotifications {
    public static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")

    /// Each [tui] key with the value Farol needs.
    /// "always" because Codex can't tell a session is hidden, and Farol ignores the session you are looking at.
    static let settings = [
        ("notifications", "true"),
        ("notification_method", "\"osc9\""),
        ("notification_condition", "\"always\""),
    ]

    static let mark = "# added by Farol"

    public enum Problem: Error, LocalizedError {
        /// The user set one of the keys to something else. Farol doesn't overwrite it.
        case conflict(key: String, value: String)
        /// [tui] is written as dotted keys or an inline table. Adding a [tui] header would break the file.
        case unusualLayout

        public var errorDescription: String? {
            switch self {
            case let .conflict(key, value):
                "Your Codex config sets tui.\(key) to \(value). Farol leaves your settings alone, so change or remove it first."
            case .unusualLayout:
                "Your Codex config sets tui options outside a [tui] table, so Farol can't add to it safely."
            }
        }
    }

    public static func isEnabled(in text: String) -> Bool {
        let values = tuiValues(in: text.components(separatedBy: "\n"))
        return settings.allSatisfy { values[$0.0].map(unquoted) == unquoted($0.1) }
    }

    /// Adds the missing keys, at the end of [tui] or in a new [tui] table. Running it again changes nothing.
    public static func enable(in text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        let values = tuiValues(in: lines)
        for (key, value) in settings {
            if let theirs = values[key], unquoted(theirs) != unquoted(value) { throw Problem.conflict(key: key, value: theirs) }
        }
        let missing = settings.filter { values[$0.0] == nil }.map { "\($0.0) = \($0.1) \(mark)" }
        if missing.isEmpty { return text }

        guard let header = lines.firstIndex(where: { isHeader($0, "tui") }) else {
            if lines.contains(where: definesTUIOutsideTable) { throw Problem.unusualLayout }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            let table = ["[tui] \(mark)"] + missing
            return ((lines.isEmpty ? [] : lines + [""]) + table + [""]).joined(separator: "\n")
        }
        // After the table's last line, before the blank lines that separate it from the next one.
        var end = sectionEnd(after: header, in: lines)
        while end > header + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        lines.insert(contentsOf: missing, at: end)
        return lines.joined(separator: "\n")
    }

    /// Removes the lines Farol added. A [tui] header Farol created goes too, unless you have added keys under it since.
    public static func disable(in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines.removeAll { !isHeader($0) && $0.hasSuffix(mark) }
        if let header = lines.firstIndex(where: { isHeader($0, "tui") && $0.hasSuffix(mark) }) {
            let end = sectionEnd(after: header, in: lines)
            let empty = lines[(header + 1)..<end].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            if empty { lines.removeSubrange(header..<end) }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: File

    public static func read() throws -> String {
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }

    public static func write(_ text: String) throws {
        try AgentHooks.replace(file, with: Data(text.utf8))
    }

    // MARK: Parsing

    /// The keys set directly in [tui], with their values as written, minus any trailing comment.
    /// ponytail: a line in a multiline array that starts with "[" reads as a table header. Codex's config has none.
    private static func tuiValues(in lines: [String]) -> [String: String] {
        guard let header = lines.firstIndex(where: { isHeader($0, "tui") }) else { return [:] }
        var values: [String: String] = [:]
        for line in lines[(header + 1)..<sectionEnd(after: header, in: lines)] {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            var value = String(parts[1])
            if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
            values[key] = value.trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// 'osc9' and "osc9" are the same string in TOML.
    private static func unquoted(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func sectionEnd(after header: Int, in lines: [String]) -> Int {
        lines[(header + 1)...].firstIndex(where: { isHeader($0) }) ?? lines.count
    }

    /// A table header like [tui] or [[array]], optionally only the one with this name.
    private static func isHeader(_ line: String, _ name: String? = nil) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("[") else { return false }
        guard let name else { return true }
        let inside = line.dropFirst().prefix { $0 != "]" }
        return inside.trimmingCharacters(in: .whitespaces) == name
    }

    private static func definesTUIOutsideTable(_ line: String) -> Bool {
        let key = line.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
        return key == "tui" || key.hasPrefix("tui.")
    }
}
