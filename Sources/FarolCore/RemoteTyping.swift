import Foundation

/// How a reply from a phone is typed into an agent's prompt.
public enum RemoteTyping {
    /// How long Return waits after a paste, so the agent has taken the text in before it is sent.
    /// An agent takes a paste in as a whole and opens any picture named in it, and a Return that comes meanwhile is lost.
    /// More lines take longer, and pictures come one to a line.
    public static func returnDelay(afterPasteOf lines: Int, elapsed: TimeInterval) -> TimeInterval {
        let settle = 0.25 + 0.15 * Double(min(max(lines, 1), 8))
        return max(0, settle - elapsed)
    }
}
