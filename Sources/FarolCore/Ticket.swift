import Foundation

/// Something to start a task from: a Jira ticket, or a GitHub or GitLab issue.
public struct Ticket: Equatable, Identifiable, Sendable {
    public enum Source: Sendable {
        case jira, github, gitlab
    }

    public let source: Source
    /// "CMB-12" in Jira, "#12" on GitHub and GitLab.
    public let key: String
    public let summary: String
    public let description: String
    /// Sent with the task, so the agent can read the comments and whatever changed since.
    public let url: URL?

    public var id: String { key }

    /// The agent's first prompt: the ticket's key and title, then what it says.
    public var task: String {
        // GitHub's line endings would count twice.
        [[key + ": " + summary, url?.absoluteString].compactMap { $0 }.joined(separator: "\n"), description]
            .joined(separator: "\n\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "CMB-12-fix-the-login". A Jira key keeps its capitals, which is how Jira links the branch to the ticket.
    public var branch: String {
        "\(key.drop { $0 == "#" })-\(NewTask.branchName(for: summary))"
    }
}
