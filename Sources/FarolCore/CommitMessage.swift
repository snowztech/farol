import Foundation

/// Asks a coding agent for a commit message, from the change about to be committed.
public enum CommitMessage {
    /// A big change is cut here, so the answer stays quick. The start of each file says the most anyway.
    static let diffLimit = 60_000

    /// Runs `agent` on the diff of `paths`, or of every uncommitted file when nil, and returns its message.
    /// The agent gets no tools, hooks or MCP servers, so it can only answer. Takes seconds, so call it off the main thread.
    /// `started` gets the process, to stop it when the sheet closes.
    public static func generate(with agent: AgentFolder, paths: [String]?, in directory: String,
                                started: (Process) -> Void = { _ in }) throws -> String {
        guard let executable = executable(of: agent.kind) else {
            throw GitError(description: "\(agent.kind.title) isn't installed.")
        }
        let diff = try self.diff(of: paths, in: directory)
        guard !diff.isEmpty else { throw GitError(description: "There is nothing to describe.") }
        let recent = (try? Git.run(["log", "-n", "20", "--format=%s"], in: directory))?.split(separator: "\n").map(String.init) ?? []
        let reply = try run(executable, arguments(for: agent.kind), input: prompt(diff: diff, recent: recent),
                            environment: environment(for: agent), in: directory, started: started)
        let message = cleaned(reply)
        guard !message.isEmpty else { throw GitError(description: "\(agent.label) didn't answer.") }
        return message
    }

    /// What git would commit for `paths`, new files written out in full since `git diff` doesn't show them.
    static func diff(of paths: [String]?, in directory: String) throws -> String {
        let only = paths.map { ["--"] + $0 } ?? []
        var text = try Git.run(["-c", "core.quotePath=false", "diff", "--find-renames", "HEAD"] + only, in: directory, trimming: false)
        let untracked = try Git.run(["-c", "core.quotePath=false", "ls-files", "--others", "--exclude-standard"] + only, in: directory)
        for path in untracked.split(separator: "\n").map(String.init) where text.utf8.count < diffLimit {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(path)
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? "(binary)"
            text += "\nNew file \(path):\n\(content)\n"
        }
        guard text.utf8.count > diffLimit else { return text }
        return String(decoding: text.utf8.prefix(diffLimit), as: UTF8.self) + "\n(diff cut here)\n"
    }

    static func prompt(diff: String, recent: [String]) -> String {
        """
        Write the git commit message for the change below. Follow this repo's own rules for commit messages if its \
        instructions have any, and the style of its recent subjects. Reply with the message only: no quotes, no code \
        block, nothing before or after it.

        Recent subjects:
        \(recent.isEmpty ? "(none yet)" : recent.joined(separator: "\n"))

        Change:
        \(diff)
        """
    }

    /// Takes off what models add around a message despite being asked not to: a lead-in line, a code block, quotes.
    static func cleaned(_ reply: String) -> String {
        let blank = { (line: Substring?) in line?.allSatisfy(\.isWhitespace) == true }
        // Only the end of a line is trimmed, so an indented list in the body keeps its shape.
        var lines = reply.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.drop(while: \.isWhitespace).hasPrefix("```") }
        while blank(lines.first) { lines.removeFirst() }
        if lines.count > 1, lines[0].trimmingCharacters(in: .whitespaces).hasSuffix(":") { lines.removeFirst() }
        while blank(lines.first) { lines.removeFirst() }
        while blank(lines.last) { lines.removeLast() }
        var message = lines.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'", "`"] where message.count > 1 && message.hasPrefix(quote) && message.hasSuffix(quote) {
            let inside = message.dropFirst().dropLast()
            // "`a` replaces `b`" starts and ends with a quote too, and those belong to the message.
            if !inside.contains(quote) { message = String(inside) }
        }
        return message
    }

    static func arguments(for kind: AgentFolder.Kind) -> [String] {
        switch kind {
        // The prompt comes on stdin. No tools and no saved session: one answer, nothing left behind.
        // Hooks and MCP servers are off too, yours and the repo's, while CLAUDE.md is still read.
        case .claude: ["-p", "--tools", "", "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config",
                       "--no-session-persistence", "--output-format", "text"]
        // ponytail: not tried against a real Codex yet. "-" reads the prompt from stdin, read-only keeps it from editing.
        case .codex: ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "-"]
        }
    }

    /// An app opened from the Finder doesn't get the shell's PATH, so the agent is looked for where its installers put it.
    private static let folders = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.claude/local"]

    static func executable(of kind: AgentFolder.Kind) -> String? {
        folders.map { "\($0)/\(kind.rawValue)" }.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private static func environment(for agent: AgentFolder) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (folders + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        if !agent.isDefault { environment[agent.kind.environmentVariable] = agent.directory.path }
        return environment
    }

    static func run(_ executable: String, _ arguments: [String], input: String, environment: [String: String],
                            in directory: String, started: (Process) -> Void) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        started(process)
        // An agent that quits before reading would otherwise kill the app with SIGPIPE. This way the write just fails.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Written from another thread, so a prompt bigger than the pipe can't wait on output nobody reads yet.
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        // Read apart for the same reason: Codex logs its progress there, enough to fill the pipe.
        var err = Data()
        let errors = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: errors) { err = stderr.fileHandleForReading.readDataToEndOfFile() }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        errors.wait()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let message = String(decoding: err.isEmpty ? out : err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(description: message.isEmpty ? "\(URL(fileURLWithPath: executable).lastPathComponent) failed" : message)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
