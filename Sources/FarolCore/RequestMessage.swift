import Foundation

/// Asks a coding agent for the title and description of a pull request, from what the branch adds to its base.
public enum RequestMessage {
    /// What the agent writes: the title and the description under it, which may be empty.
    public struct Text: Equatable {
        public let title: String
        public let body: String
    }

    /// Runs `agent` on the commits and the diff of `head` against `base`, a branch on the server like main.
    /// Like the commit message the agent gets no tools, so it can only answer. Takes seconds, so call it off the main thread.
    /// `started` gets the process, to stop it when the sheet closes.
    public static func generate(with agent: AgentFolder, head: String, base: String, in directory: String,
                                started: (Process) -> Void = { _ in }) throws -> Text {
        guard let arguments = CommitMessage.arguments(for: agent.kind) else {
            throw GitError(description: "\(agent.kind.title) can't write pull requests yet.")
        }
        guard let executable = agent.kind.executable else { throw GitError(description: "\(agent.kind.title) isn't installed.") }
        let start = try reference(of: base, in: directory)
        let commits = try Git.run(["log", "--format=%s%n%b%n--", "\(start)..\(head)"], in: directory)
        guard !commits.isEmpty else { throw GitError(description: "\(head) has nothing on top of \(base) to describe.") }
        var diff = try Git.run(["-c", "core.quotePath=false", "diff", "--find-renames", "\(start)...\(head)"], in: directory, trimming: false)
        if diff.utf8.count > CommitMessage.diffLimit {
            diff = String(decoding: diff.utf8.prefix(CommitMessage.diffLimit), as: UTF8.self) + "\n(diff cut here)\n"
        }
        // A repo's own form for pull requests says what it wants in the description.
        let template = ["pull_request_template.md", "PULL_REQUEST_TEMPLATE.md"].lazy
            .compactMap { try? String(contentsOfFile: directory + "/.github/" + $0, encoding: .utf8) }.first
        let reply = try CommitMessage.run(executable, arguments, input: prompt(commits: commits, diff: diff, template: template),
                                          environment: CommitMessage.environment(for: agent), in: directory, started: started)
        guard let text = parse(reply) else { throw GitError(description: "\(agent.label) didn't answer.") }
        return text
    }

    /// What the sheet starts with before any agent is asked. The first commit gives the title and the description, the others are listed under it.
    /// Nil when `base` isn't known here or the branch adds nothing to it.
    public static func fromCommits(head: String, base: String, in directory: String) -> Text? {
        guard let start = try? reference(of: base, in: directory),
              let log = try? Git.run(["log", "--reverse", "--format=%s%x1f%b%x1e", "\(start)..\(head)"], in: directory, trimming: false)
        else { return nil }
        let commits = log.split(separator: "\u{1e}").compactMap { entry -> (subject: String, body: String)? in
            let fields = entry.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            let subject = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty else { return nil }
            return (subject, fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        }
        guard let first = commits.first else { return nil }
        let others = commits.dropFirst().map { "- " + $0.subject }
        let body = ([first.body].filter { !$0.isEmpty } + (others.isEmpty ? [] : [others.joined(separator: "\n")])).joined(separator: "\n\n")
        return Text(title: first.subject, body: body)
    }

    /// `base` as git can read it: the server's copy when there is one, as the request is made against that.
    static func reference(of base: String, in directory: String) throws -> String {
        let remote = History.pushRemote(in: directory)
        for candidate in ["\(remote)/\(base)", base] where (try? Git.run(["rev-parse", "--verify", "--quiet", candidate], in: directory)) != nil {
            return candidate
        }
        throw GitError(description: "\(base) isn't known here. Fetch from the server first.")
    }

    static func prompt(commits: String, diff: String, template: String?) -> String {
        """
        Write the title and the description of the pull request for the branch below. Follow this repo's own rules for \
        pull requests if its instructions have any. Reply with the title on the first line, a blank line, then the \
        description in Markdown: no quotes, no code block around it, nothing before or after it.
        \(template.map { "\nThe repo's template for the description:\n\($0)\n" } ?? "")
        Commits:
        \(commits)

        Change:
        \(diff)
        """
    }

    /// The first line is the title, with the "Title:" or "#" models put in front of it taken off, and the rest the description.
    static func parse(_ reply: String) -> Text? {
        let message = CommitMessage.cleaned(reply)
        guard !message.isEmpty else { return nil }
        let lines = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        var title = lines[0].trimmingCharacters(in: .whitespaces)
        for prefix in ["Title:", "title:", "#"] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !title.isEmpty else { return nil }
        let body = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return Text(title: title, body: body)
    }
}
