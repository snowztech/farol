import Foundation

/// How a reply from a phone is typed into an agent's prompt.
public enum RemoteTyping {
    /// How long Return waits after a paste, so the agent has taken the text in before it is sent.
    /// An agent takes a paste in as a whole and opens any picture named in it, and a Return that comes meanwhile is lost.
    /// More lines take longer, and a picture much longer, since the agent reads the whole file.
    public static func returnDelay(afterPasteOf text: String, elapsed: TimeInterval) -> TimeInterval {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let pictures = lines.filter { $0.contains(picturesFolder) }.count
        let settle = 0.25 + 0.15 * Double(min(lines.count, 8)) + 0.6 * Double(min(pictures, 4))
        return max(0, settle - elapsed)
    }

    /// Where the Mac keeps pictures from a phone, as it appears in the path a reply names each one by.
    public static let picturesFolder = "/Farol/Attachments/"
}
