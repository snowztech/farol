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

    /// The folder a conversation's log is in. Claude Code keeps its logs under `projects` in its config folder, and Codex under `sessions`.
    public init?(log: String) {
        if let range = log.range(of: "/projects/") {
            self.init(kind: .claude, directory: URL(fileURLWithPath: String(log[..<range.lowerBound])))
        } else if let range = log.range(of: "/sessions/") {
            self.init(kind: .codex, directory: URL(fileURLWithPath: String(log[..<range.lowerBound])))
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

    /// The folder saved as the last choice. Older versions saved just "claude" or "codex".
    public static func choice(_ saved: String, in folders: [AgentFolder]) -> AgentFolder? {
        folders.first { $0.id == saved } ?? folders.first { $0.isDefault && $0.kind.rawValue == saved } ?? folders.first
    }
}
