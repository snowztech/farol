import Foundation

/// Your Linear issues, through the Linear CLI (schpet/linear-cli). Linear ships no CLI of its own, as Atlassian ships none for Jira.
/// The CLI keeps its API key in the Keychain, so Farol only runs it and never sees the key.
public enum Linear {
    public static func toolState() -> Forge.ToolState {
        guard (try? shell("command -v linear")) != nil else { return .missing }
        guard let me = try? run(["auth", "whoami"]) else { return .loggedOut }
        return .connected(account: me.split(separator: "\n").first.map(String.init))
    }

    /// Logged in once, as far as the CLI's own file says, so New Task can hold a place for the tickets before asking.
    public static var isSetUp: Bool {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config"
        return FileManager.default.fileExists(atPath: base + "/linear/credentials.toml")
    }

    public static let docs = "https://github.com/schpet/linear-cli"

    public static func setupCommand(from state: Forge.ToolState) -> String {
        (state == .missing ? "brew install schpet/tap/linear && " : "") + "linear auth login"
    }

    /// Yours and not done, newest first. One query, so the descriptions come with them.
    static let query = """
        { viewer { assignedIssues(first: 50, orderBy: updatedAt, \
        filter: { state: { type: { nin: ["completed", "canceled"] } } }) \
        { nodes { identifier title description url } } } }
        """

    public static func tickets() throws -> [Ticket] {
        tickets(from: try run(["api", query]))
    }

    static func tickets(from output: String) -> [Ticket] {
        guard let start = output.firstRange(of: #/(?m)^\{/#)?.lowerBound,
              let answer = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any] else {
            return []
        }
        // The answer as the API gives it, or its data alone.
        let viewer = ((answer["data"] as? [String: Any]) ?? answer)["viewer"] as? [String: Any]
        let issues = (viewer?["assignedIssues"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return issues.compactMap { issue in
            guard let key = issue["identifier"] as? String, let summary = issue["title"] as? String else { return nil }
            let description = (issue["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Ticket(source: .linear, key: key, summary: summary, description: description,
                          url: (issue["url"] as? String).flatMap(URL.init(string:)))
        }
    }

    private static func run(_ arguments: [String]) throws -> String {
        try shell("exec linear " + arguments.map(NewTask.shellQuoted).joined(separator: " "))
    }

    /// A login shell, so the CLI is found where Homebrew or npm put it.
    private static func shell(_ command: String) throws -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return try Git.run(shell, ["-ilc", command], in: NSHomeDirectory(), named: "linear tickets")
    }
}
