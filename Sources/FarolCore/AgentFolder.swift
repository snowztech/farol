import Foundation

/// One config folder of Claude Code or Codex. Someone with a work and a personal account has several.
public struct AgentFolder: Equatable, Hashable {
    public enum Kind: String, CaseIterable {
        case claude, codex

        var title: String { self == .claude ? "Claude Code" : "Codex" }
        var environmentVariable: String { self == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME" }
        /// The file whose presence says a look-alike folder really is a config folder.
        var configFile: String { self == .claude ? "settings.json" : "config.toml" }
    }

    public let kind: Kind
    public let directory: URL

    public init(kind: Kind, directory: URL) {
        self.kind = kind
        self.directory = directory
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
        var parts = [kind.rawValue]
        if !isDefault { parts.insert("\(kind.environmentVariable)=\(NewTask.shellQuoted(directory.path))", at: 0) }
        if let task { parts.append(NewTask.shellQuoted(task)) }
        return parts.joined(separator: " ")
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
