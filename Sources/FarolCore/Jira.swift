import Foundation

/// Jira tickets to start a task from, read through jira-cli, the `jira` command.
public enum Jira {
    /// Whether jira-cli is there and has an account, for Settings. Runs a shell, so call it off the main thread.
    public static func toolState() -> Forge.ToolState {
        guard (try? shell("command -v jira")) != nil else { return .missing }
        guard let me = try? run(["me"]) else { return .loggedOut }
        // The shell's startup files may print before the tool does.
        return .connected(account: me.split(separator: "\n").last.map(String.init))
    }

    /// Whether jira-cli has been set up, read from its config file, which costs nothing next to asking the tool.
    public static var isSetUp: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.config/.jira/.config.yml")
    }

    /// Where jira-cli's own documentation is, for installing it and setting it up.
    public static let docs = "https://github.com/ankitpokhrel/jira-cli"

    /// Typed into a terminal to get from `state` to connected. Setting up asks questions, so it can't run in the background.
    public static func setupCommand(from state: Forge.ToolState) -> String {
        (state == .missing ? "brew install jira-cli && " : "") + "jira init"
    }

    /// A team's board. A scrum board works in sprints, and a kanban board has everything on it at once.
    public struct Board: Equatable, Hashable, Sendable {
        public let id: Int
        public let name: String
        public let sprints: Bool

        /// Reads a line of `jira board list`: the id, the name, then scrum or kanban, with tabs between.
        public init?(line: String) {
            let parts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3, let id = Int(parts[0]) else { return nil }
            (self.id, name, sprints) = (id, parts[1], parts[2] == "scrum")
        }

        /// The same line back, which is how the chosen board is kept in the settings.
        public var line: String { "\(id)\t\(name)\t\(sprints ? "scrum" : "kanban")" }
    }

    /// Where the chosen board is kept. Empty lists your own tickets instead.
    public static let boardKey = "jira.board"

    /// The boards of the project jira-cli is set up for. Talks to Jira, so call it off the main thread.
    public static func boards() -> [Board] {
        ((try? run(["board", "list"])) ?? "").split(separator: "\n").compactMap { Board(line: String($0)) }
    }

    /// Where the account's picture is. jira-cli can't say, so Jira is asked with the same account and token.
    public static func avatar() -> URL? {
        (try? api("api/2/myself")).flatMap(avatar(fromUser:))
    }

    /// Asks Jira what jira-cli has no command for, as the account and with the token jira-cli uses.
    private static func api(_ path: String, _ query: [String] = []) throws -> String {
        // ponytail: the token as a password, which Jira Cloud takes. Data Center's own tokens get no answer here.
        let server = #"$(sed -n 's/^server: //p' ~/.config/.jira/.config.yml)"#
        let fields = query.map { " --data-urlencode " + NewTask.shellQuoted($0) }.joined()
        // printf is part of the shell, so the token never shows in the list of running commands.
        return try shell(#"printf 'user = "%s:%s"' "$(jira me)" "$JIRA_API_TOKEN" | curl -fsS -K - --get\#(fields) "\#(server)/rest/\#(path)""#)
    }

    /// Reads the picture from Jira's answer about the logged in user.
    static func avatar(fromUser output: String) -> URL? {
        guard let start = output.firstRange(of: #/(?m)^\{/#)?.lowerBound,
              let user = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any] else {
            return nil
        }
        return ((user["avatarUrls"] as? [String: Any])?["48x48"] as? String).flatMap(URL.init(string:))
    }

    /// The open tickets of `board`, or your own without one, the latest updated first.
    /// Talks to Jira, so call it off the main thread.
    public static func tickets(on board: Board? = nil) throws -> [Ticket] {
        // ponytail: the first 50. Searching on Jira's side would reach the rest of a long board.
        guard let board else {
            return tickets(from: try run(["issue", "list", "--jql", "assignee = currentUser() AND statusCategory != Done",
                                          "--order-by", "updated", "--paginate", "50", "--raw"]))
        }
        // A scrum board also holds its backlog, which nobody is working on yet.
        let open = (board.sprints ? "sprint in openSprints() AND " : "") + "statusCategory != Done ORDER BY updated DESC"
        return tickets(from: try api("agile/1.0/board/\(board.id)/issue",
                                     ["jql=\(open)", "fields=summary,description", "maxResults=50"]))
    }

    /// Reads jira-cli's list, or Jira's own answer with the list under "issues".
    static func tickets(from output: String) -> [Ticket] {
        // The shell's startup files may print before the tool does, so the answer is read from where it opens.
        guard let start = output.firstRange(of: #/(?m)^[\[{]/#)?.lowerBound,
              let answer = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)),
              let list = (answer as? [String: Any])?["issues"] as? [[String: Any]] ?? answer as? [[String: Any]] else {
            return []
        }
        return list.compactMap { issue in
            guard let key = issue["key"] as? String, let fields = issue["fields"] as? [String: Any],
                  let summary = fields["summary"] as? String else { return nil }
            let description = text(of: fields["description"]).trimmingCharacters(in: .whitespacesAndNewlines)
            return Ticket(source: .jira, key: key, summary: summary, description: description)
        }
    }

    /// Jira Cloud sends a description as a tree of nodes, and Jira Data Center as plain text.
    static func text(of node: Any?) -> String {
        if let text = node as? String { return text }
        guard let node = node as? [String: Any] else { return "" }
        if let text = node["text"] as? String { return text }
        // A mention carries its name here, and a pasted link its address.
        let attributes = node["attrs"] as? [String: Any]
        if let text = (attributes?["text"] ?? attributes?["url"]) as? String { return text }
        let inner = (node["content"] as? [Any] ?? []).map(text(of:)).joined()
        switch node["type"] as? String {
        case "paragraph", "heading", "codeBlock": return inner + "\n"
        case "listItem": return "- " + inner
        case "hardBreak": return "\n"
        default: return inner
        }
    }

    private static func run(_ arguments: [String]) throws -> String {
        try shell("exec jira " + arguments.map(NewTask.shellQuoted).joined(separator: " "))
    }

    /// jira-cli takes its token from the environment, which most people set in their shell's startup files.
    /// An app opened from the Dock never reads those, so the tool runs through your shell, as it would in a terminal.
    private static func shell(_ command: String) throws -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return try Git.run(shell, ["-ilc", command], in: NSHomeDirectory())
    }
}
