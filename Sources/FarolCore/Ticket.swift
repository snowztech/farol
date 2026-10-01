import Foundation

/// Something to start a task from: a Jira ticket or a GitHub issue.
public struct Ticket: Equatable, Identifiable, Sendable {
    public enum Source: Sendable {
        case jira, github
    }

    public let source: Source
    /// "CMB-12" in Jira, "#12" on GitHub.
    public let key: String
    public let summary: String
    public let description: String

    public var id: String { key }

    /// The agent's first prompt: the ticket's key and title, then what it says.
    public var task: String {
        // The prompt is typed into a shell, where a tab asks for completions and GitHub's line endings count twice.
        "\(key): \(summary)\n\n\(description)"
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\t", with: "  ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "CMB-12-fix-the-login". A Jira key keeps its capitals, which is how Jira links the branch to the ticket.
    public var branch: String {
        "\(key.drop { $0 == "#" })-\(NewTask.branchName(for: summary))"
    }
}
