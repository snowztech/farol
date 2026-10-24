import Foundation

/// One config folder of a coding agent. Someone with a work and a personal account has several.
public struct AgentFolder: Equatable, Hashable {
    /// Every agent Farol knows. What differs between them is answered here, so adding one starts with a case.
    /// The compiler then names each place that has to say how the new agent does it.
    public enum Kind: String, CaseIterable {
        case claude, codex, opencode, pi

        var title: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .opencode: "OpenCode"
            case .pi: "Pi"
            }
        }

        var environmentVariable: String {
            switch self {
            case .claude: "CLAUDE_CONFIG_DIR"
            case .codex: "CODEX_HOME"
            case .opencode: "OPENCODE_CONFIG_DIR"
            case .pi: "PI_CODING_AGENT_DIR"
            }
        }

        /// Where the agent keeps its config when nothing picks another, from the home folder.
        var defaultFolder: String {
            switch self {
            case .claude: ".claude"
            case .codex: ".codex"
            case .opencode: ".config/opencode"
            case .pi: ".pi/agent"
            }
        }

        /// The file whose presence says a look-alike folder really is a config folder.
        var configFile: String {
            switch self {
            case .claude, .pi: "settings.json"
            case .codex: "config.toml"
            case .opencode: "opencode.json"
            }
        }

        /// Listed before it is set up, as the two agents most people use. The others show once their folder is there.
        var listedWhenMissing: Bool { self == .claude || self == .codex }

        /// What starts it on a first prompt, as words for a shell.
        func prompt(_ task: String) -> [String] {
            (self == .opencode ? ["--prompt"] : []) + [NewTask.shellQuoted(task)]
        }

        /// What picks a conversation up where it stopped, as words for a shell.
        func resume(_ id: String) -> [String] {
            let flag = switch self {
            case .claude: "--resume"
            case .codex: "resume"
            case .opencode, .pi: "--session"
            }
            return [flag, NewTask.shellQuoted(id)]
        }

        /// An app opened from the Finder doesn't get the shell's PATH, so the agent is looked for where its installers put it.
        static let installFolders = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.claude/local",
                                     NSHomeDirectory() + "/.opencode/bin"]

        public var executable: String? {
            Self.installFolders.map { "\($0)/\(rawValue)" }.first(where: FileManager.default.isExecutableFile(atPath:))
        }
    }

    public let kind: Kind
    public let directory: URL

    public init(kind: Kind, directory: URL) {
        self.kind = kind
        self.directory = directory
    }

    /// The folder a conversation's log is in: `<folder>/projects/<project>/<id>.jsonl` for Claude Code, `<folder>/sessions/<y>/<m>/<d>/<file>.jsonl` for Codex.
    /// Pi writes `<folder>/sessions/<project>/<file>.jsonl`.
    /// Read by position, so a config folder that is itself inside a `projects` or `sessions` folder isn't mistaken for the other agent.
    public init?(log: String) {
        let file = URL(fileURLWithPath: log)
        // Rebuilt from the path, which drops the trailing slash that would make it unequal to the same folder found elsewhere.
        func up(_ levels: Int) -> URL { URL(fileURLWithPath: (0..<levels).reduce(file) { url, _ in url.deletingLastPathComponent() }.path) }
        if up(2).lastPathComponent == "projects" {
            self.init(kind: .claude, directory: up(3))
        } else if up(4).lastPathComponent == "sessions" {
            self.init(kind: .codex, directory: up(5))
        } else if up(2).lastPathComponent == "sessions" {
            self.init(kind: .pi, directory: up(3))
        } else {
            return nil
        }
    }

    private var name: String { directory.lastPathComponent.drop { $0 == "." }.description }

    /// The folder the agent uses when nothing picks another.
    public var isDefault: Bool { name == URL(fileURLWithPath: kind.defaultFolder).lastPathComponent.drop { $0 == "." }.description }

    /// "Claude Code" for ~/.claude, "Claude Code (work)" for ~/.claude-work.
    public var label: String {
        let prefix = kind.rawValue + "-"
        if isDefault { return kind.title }
        return "\(kind.title) (\(name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name))"
    }

    public var id: String { directory.path }

    /// Starts the agent on this folder, with `task` as its first prompt when there is one.
    /// The default folder starts plainly, since the agent finds it by itself.
    public func command(task: String? = nil) -> String {
        line(task.map(kind.prompt) ?? [])
    }

    /// Picks up the conversation `id` where it stopped. Run in the folder it started in, where Claude Code looks for it.
    public func resume(_ id: String) -> String {
        line(kind.resume(id))
    }

    private func line(_ words: [String]) -> String {
        ([launcher] + words).joined(separator: " ")
    }

    private var launcher: String {
        isDefault ? kind.rawValue : "\(kind.environmentVariable)=\(NewTask.shellQuoted(directory.path)) \(kind.rawValue)"
    }

    /// The default folder, every `<default>-*` folder beside it that holds the agent's config file, and the folder the environment names.
    /// The config file keeps out look-alikes such as backups.
    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> [AgentFolder] {
        let manager = FileManager.default
        return Kind.allCases.flatMap { kind -> [AgentFolder] in
            let base = home.appendingPathComponent(kind.defaultFolder)
            let prefix = base.lastPathComponent + "-"
            let names = (try? manager.contentsOfDirectory(atPath: base.deletingLastPathComponent().path)) ?? []
            var directories = kind.listedWhenMissing || manager.fileExists(atPath: base.path) ? [base] : []
            directories += names.sorted()
                .filter { $0.hasPrefix(prefix) && $0.count > prefix.count }
                .map { base.deletingLastPathComponent().appendingPathComponent($0, isDirectory: true) }
                .filter { manager.fileExists(atPath: $0.appendingPathComponent(kind.configFile).path) }
            if let value = environment[kind.environmentVariable], !value.isEmpty {
                directories.append(URL(fileURLWithPath: value, isDirectory: true))
            }
            var seen = Set<String>()
            return directories
                .filter { seen.insert($0.standardizedFileURL.path).inserted }
                .map { AgentFolder(kind: kind, directory: $0) }
        }
    }

    /// Codex's interactive TUI runs no hooks, so its conversation is read from its logs: of those it started in `folder`, the one written last since `since`.
    /// Asked as a turn ends, that's the log Codex just wrote, which also follows `/new` and `codex resume`.
    /// ponytail: two Codex in the same folder ending turns at the same moment could be swapped. A hook from the TUI would end the guess.
    public static func lastCodexConversation(in folders: [AgentFolder], startedIn folder: String, since: Date,
                                             now: Date = Date()) -> AgentConversation? {
        let calendar = Calendar.current
        let wanted = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        var best: (log: URL, modified: Date, id: String)?
        for codex in folders where codex.kind == .codex {
            // Codex keeps a folder per day, so only the days since `since` are looked at.
            var day = calendar.startOfDay(for: since)
            while day <= now {
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                let logs = codex.directory.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
                let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                          modified >= since, modified > best?.modified ?? .distantPast,
                          let start = codexStart(of: file), URL(fileURLWithPath: start.folder).resolvingSymlinksInPath().path == wanted else { continue }
                    best = (file, modified, start.id)
                }
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
        }
        return best.map { AgentConversation(id: $0.id, log: $0.log.path) }
    }

    /// The conversation's id and folder, from the first line of a Codex log.
    static func codexStart(of log: URL) -> (id: String, folder: String)? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        var line = Data()
        // The first line carries Codex's instructions too, some tens of kilobytes.
        while line.count < 1 << 20, let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            if let end = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                line.append(chunk[..<end])
                break
            }
            line.append(chunk)
        }
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any], let id = payload["id"] as? String, let folder = payload["cwd"] as? String else { return nil }
        return (id, folder)
    }

    /// The folder saved as the last choice. Older versions saved just "claude" or "codex".
    public static func choice(_ saved: String, in folders: [AgentFolder]) -> AgentFolder? {
        folders.first { $0.id == saved } ?? folders.first { $0.isDefault && $0.kind.rawValue == saved } ?? folders.first
    }
}
