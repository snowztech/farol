/// Agents decorate the terminal title with their status, which the sidebar dot already shows.
public enum AgentTitle {
    /// Leading separators an agent leaves when part of its title is empty, like Codex's " | farol" before a conversation has a name.
    /// Includes the en and em dashes, written as code points.
    private static let separators: Set<Character> = ["|", "·", "•", "-", "\u{2013}", "\u{2014}", ":"]

    /// Drops the status glyph and any leading separator: "✳ Claude Code" gives "Claude Code", " | farol" gives "farol".
    public static func withoutStatus(_ title: String) -> String {
        String(title.drop { character in
            character.isWhitespace || separators.contains(character)
                || character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .otherSymbol }
        })
    }
}
