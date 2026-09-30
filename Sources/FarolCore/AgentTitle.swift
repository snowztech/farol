/// Agents decorate the terminal title with their status, which the sidebar dot already shows.
public enum AgentTitle {
    /// How agents join parts of a title, like Codex's "<conversation> | <project>". Spaced, so "a|b" or "vim a-b" stay whole.
    /// Includes the en and em dashes, written as code points.
    private static let joiners = [" | ", " · ", " \u{2013} ", " \u{2014} "]
    private static let codexSpinners = Set("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    /// Codex's interactive TUI does not run lifecycle hooks, but it does report the same states in its terminal title.
    public static func event(from previous: String, to current: String) -> AgentEvent? {
        let before = codexStatus(previous)
        let after = codexStatus(current)
        guard before != after else { return nil }
        switch after {
        case .working: return .working
        case .waiting: return .waiting
        case nil where before != nil: return .done
        case nil: return nil
        case .done: return nil
        }
    }

    /// Drops the status glyph and the extra parts: "✳ Claude Code" gives "Claude Code", "Design codebase | farol" gives "Design codebase".
    /// An empty first part, as in " | farol", gives the next one.
    public static func withoutStatus(_ title: String) -> String {
        let text = String(title.drop { character in
            character.isWhitespace || character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .otherSymbol }
        })
        // Padded so a joiner at the very start, as in "| farol", is found too.
        var parts = [" " + text + " "]
        for joiner in joiners { parts = parts.flatMap { $0.components(separatedBy: joiner) } }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }

    private static func codexStatus(_ title: String) -> AgentStatus? {
        let text = title.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[ ! ] Action Required") || text.hasPrefix("[ . ] Action Required") { return .waiting }
        if text.first.map(codexSpinners.contains) == true { return .working }
        return nil
    }
}
