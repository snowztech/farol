import Foundation

/// One config folder of Claude Code or Codex. Someone with a work and a personal account has several.
public struct AgentFolder: Equatable, Hashable {
    public enum Kind: String, CaseIterable {
        case claude, codex

        var title: String { self == .claude ? "Claude Code" : "Codex" }
        var environmentVariable: String { self == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME" }
        /// The file whose presence says a look-alike folder really is a config folder.
        var configFile: String { self == .claude ? "settings.json" : "config.toml" }

        /// An app opened from the Finder doesn't get the shell's PATH, so the agent is looked for where its installers put it.
        static let installFolders = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.claude/local"]

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
    /// Read by position, so a config folder that is itself inside a `projects` or `sessions` folder isn't mistaken for the other agent.
    public init?(log: String) {
        let file = URL(fileURLWithPath: log)
        // Rebuilt from the path, which drops the trailing slash that would make it unequal to the same folder found elsewhere.
        func up(_ levels: Int) -> URL { URL(fileURLWithPath: (0..<levels).reduce(file) { url, _ in url.deletingLastPathComponent() }.path) }
        if up(2).lastPathComponent == "projects" {
            self.init(kind: .claude, directory: up(3))
        } else if up(4).lastPathComponent == "sessions" {
            self.init(kind: .codex, directory: up(5))
        } else {
            return nil
        }
    }

    private var name: String { directory.lastPathComponent.drop { $0 == "." }.description }

    /// The folder the agent uses when nothing picks another.
    public var isDefault: Bool { name == kind.rawValue }

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
        ([launcher] + (task.map { [NewTask.shellQuoted($0)] } ?? [])).joined(separator: " ")
    }

    /// Picks up the conversation `id` where it stopped. Run in the folder it started in, where Claude Code looks for it.
    public func resume(_ id: String) -> String {
        [launcher, kind == .claude ? "--resume" : "resume", NewTask.shellQuoted(id)].joined(separator: " ")
    }

    private var launcher: String {
        isDefault ? kind.rawValue : "\(kind.environmentVariable)=\(NewTask.shellQuoted(directory.path)) \(kind.rawValue)"
    }

    /// The default folder, every `<default>-*` folder that holds the agent's config file, and the folder the environment names.
    /// The config file keeps out look-alikes such as backups.
    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> [AgentFolder] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: home.path)) ?? []
        return Kind.allCases.flatMap { kind -> [AgentFolder] in
            let prefix = "." + kind.rawValue + "-"
            var directories = [home.appendingPathComponent("." + kind.rawValue)]
            directories += names.sorted()
                .filter { $0.hasPrefix(prefix) && $0.count > prefix.count }
                .map { home.appendingPathComponent($0, isDirectory: true) }
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
