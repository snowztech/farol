import Foundation

/// A key that isn't text, for a prompt that waits on Return or an arrow.
public enum PaneKey: String, Codable, CaseIterable, Sendable {
    case enter, escape, tab, up, down, left, right
    /// Control-C.
    case interrupt
}

/// Something `farol` asks the app about a session, answered on the same connection.
/// A session is named by its place in the sidebar, from 1, as in ⌘1 to ⌘9.
public enum PaneRequest: Codable, Equatable, Sendable {
    case sessions
    case read(session: Int)
    /// Goes in whole, as a paste, and waits for a Return.
    case send(session: Int, text: String)
    case key(session: Int, key: PaneKey)
}

/// The app's answer: the text that was asked for, or why it said no.
public enum PaneAnswer: Codable, Equatable, Sendable {
    case text(String)
    case refused(String)
}
