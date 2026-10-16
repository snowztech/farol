import Foundation

/// Something an agent takes after a slash.
public struct AgentCommand: Equatable, Sendable {
    /// Without the slash, like "compact" or "frontend-design:review".
    public var name: String
    public var detail: String?
    /// It opens a picker in the agent's terminal, like /model.
    public var menu: Bool
    /// Called with a dollar sign rather than a slash, as Codex mentions a skill: `$name`.
    public var mention: Bool

    public init(name: String, detail: String? = nil, menu: Bool = false, mention: Bool = false) {
        self.name = name
        self.detail = detail
        self.menu = menu
        self.mention = mention
    }
}

/// What an agent takes after a slash: its own commands, and the skills and commands of yours, the project's and your plugins'.
/// Read from the agent's config folder and the project, so a phone can offer them as you type.
public enum AgentCommands {
    /// For the agent whose conversation is `log`, working in `project`. Without a log, Claude Code in its default folder.
    public static func list(log: String?, project: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentCommand] {
        let folder = folder(of: log, home: home)
        var all: [AgentCommand]
        switch folder.kind {
        case .claude:
            all = claude
            let project = project.map { URL(fileURLWithPath: $0).appendingPathComponent(".claude") }
            for base in [folder.directory] + (project.map { [$0] } ?? []) {
                all += markdown(in: base.appendingPathComponent("commands"))
                all += skills(in: base.appendingPathComponent("skills"))
            }
            all += plugins(in: folder.directory)
        case .codex:
            all = codex + markdown(in: folder.directory.appendingPathComponent("prompts"), prefix: "prompts:")
            // Codex mentions skills with a dollar sign. They are yours, the project's, the older place in its own folder, and its own.
            let roots = [home.appendingPathComponent(".agents/skills"), folder.directory.appendingPathComponent("skills"),
                         folder.directory.appendingPathComponent("skills/.system")]
                + (project.map { [URL(fileURLWithPath: $0).appendingPathComponent(".agents/skills")] } ?? [])
            let off = disabledSkills(in: folder.directory)
            all += roots.flatMap { skills(in: $0, skipping: off) }.map { skill in
                var skill = skill
                skill.mention = true
                return skill
            }
        }
        var seen = Set<String>()
        return all.filter { seen.insert(($0.mention ? "$" : "/") + $0.name).inserted }.sorted { $0.name < $1.name }
    }

    /// Claude Code keeps its logs under `projects` in its config folder, and Codex under `sessions`.
    static func folder(of log: String?, home: URL) -> AgentFolder {
        if let log, let range = log.range(of: "/projects/") {
            return AgentFolder(kind: .claude, directory: URL(fileURLWithPath: String(log[..<range.lowerBound])))
        }
        if let log, let range = log.range(of: "/sessions/") {
            return AgentFolder(kind: .codex, directory: URL(fileURLWithPath: String(log[..<range.lowerBound])))
        }
        return AgentFolder(kind: .claude, directory: home.appendingPathComponent(".claude"))
    }

    /// Markdown files, each one a command named by its path, with a colon for each folder.
    static func markdown(in directory: URL, prefix: String = "") -> [AgentCommand] {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        // Both resolved, since a folder reached through a link lists its files by where they really are.
        let base = directory.resolvingSymlinksInPath().path + "/"
        return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }.compactMap { file in
            let path = file.resolvingSymlinksInPath().deletingPathExtension().path
            guard path.hasPrefix(base), let text = head(of: file) else { return nil }
            return AgentCommand(name: prefix + path.dropFirst(base.count).replacingOccurrences(of: "/", with: ":"), detail: describe(text))
        }
    }

    /// A folder per skill, each with a SKILL.md. One that says it is not for people to call is left out.
    static func skills(in directory: URL, prefix: String = "", skipping off: Set<String> = []) -> [AgentCommand] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            let file = folder.appendingPathComponent("SKILL.md")
            guard !off.contains(file.resolvingSymlinksInPath().path), let text = head(of: file) else { return nil }
            let fields = frontmatter(text)
            if fields["user-invocable"] == "false" { return nil }
            return AgentCommand(name: prefix + (fields["name"] ?? folder.lastPathComponent), detail: describe(text))
        }
    }

    /// The commands and skills of the plugins turned on in the config folder, each under its plugin's name.
    static func plugins(in folder: URL) -> [AgentCommand] {
        guard let installed = json(folder.appendingPathComponent("plugins/installed_plugins.json"))?["plugins"] as? [String: [[String: Any]]],
              let enabled = json(folder.appendingPathComponent("settings.json"))?["enabledPlugins"] as? [String: Bool] else { return [] }
        return installed.flatMap { key, installs -> [AgentCommand] in
            guard enabled[key] == true, let path = installs.first?["installPath"] as? String else { return [] }
            let name = String(key.prefix { $0 != "@" }) + ":"
            let root = URL(fileURLWithPath: path)
            return markdown(in: root.appendingPathComponent("commands"), prefix: name) + skills(in: root.appendingPathComponent("skills"), prefix: name)
        }
    }

    /// The skills Codex's config turns off, by their SKILL.md: a `[[skills.config]]` table with its `path` and `enabled = false`.
    static func disabledSkills(in folder: URL) -> Set<String> {
        guard let config = try? String(contentsOf: folder.appendingPathComponent("config.toml"), encoding: .utf8) else { return [] }
        var off = Set<String>()
        for table in config.components(separatedBy: "[[skills.config]]").dropFirst() {
            let lines = table.split(separator: "\n").prefix { !$0.hasPrefix("[") }.map { $0.replacingOccurrences(of: " ", with: "") }
            guard lines.contains("enabled=false"), let path = lines.first(where: { $0.hasPrefix("path=") }) else { continue }
            off.insert(URL(fileURLWithPath: path.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))).resolvingSymlinksInPath().path)
        }
        return off
    }

    /// The `key: value` lines between the `---` that open a file.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = value
        }
        return fields
    }

    /// Its description, or else its first line of prose, short enough for one row on a phone.
    static func describe(_ text: String) -> String? {
        var line = frontmatter(text)["description"]
        if line?.isEmpty ?? true {
            let body = text.hasPrefix("---") ? text.components(separatedBy: "\n---").dropFirst().joined(separator: "\n---") : text
            line = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        guard let line, !line.isEmpty else { return nil }
        return line.count > 140 ? String(line.prefix(139)) + "…" : line
    }

    /// The start of a file, which is all its name and description need.
    private static func head(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4096)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func json(_ file: URL) -> [String: Any]? {
        (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Claude Code's own commands. Those that open a picker in its terminal say so.
    static let claude = [
        AgentCommand(name: "add-dir", detail: "Add a folder the agent can work in"),
        AgentCommand(name: "agents", detail: "Manage subagents", menu: true),
        AgentCommand(name: "clear", detail: "Start over with an empty conversation"),
        AgentCommand(name: "compact", detail: "Summarize the conversation to free up context"),
        AgentCommand(name: "config", detail: "Open the settings", menu: true),
        AgentCommand(name: "context", detail: "Show what fills the context"),
        AgentCommand(name: "cost", detail: "Show what this session cost"),
        AgentCommand(name: "doctor", detail: "Check the installation"),
        AgentCommand(name: "export", detail: "Export the conversation", menu: true),
        AgentCommand(name: "help", detail: "List the commands"),
        AgentCommand(name: "hooks", detail: "Manage hooks", menu: true),
        AgentCommand(name: "init", detail: "Write a CLAUDE.md for this project"),
        AgentCommand(name: "mcp", detail: "Manage MCP servers", menu: true),
        AgentCommand(name: "memory", detail: "Edit the memory files", menu: true),
        AgentCommand(name: "model", detail: "Pick the model", menu: true),
        AgentCommand(name: "permissions", detail: "Manage what it may do", menu: true),
        AgentCommand(name: "plugin", detail: "Manage plugins", menu: true),
        AgentCommand(name: "resume", detail: "Go back to an earlier conversation", menu: true),
        AgentCommand(name: "review", detail: "Review a pull request"),
        AgentCommand(name: "rewind", detail: "Go back to an earlier point", menu: true),
        AgentCommand(name: "status", detail: "Show the account and the model", menu: true),
        AgentCommand(name: "usage", detail: "Show the plan's usage"),
    ]

    /// Codex's own commands.
    static let codex = [
        AgentCommand(name: "approvals", detail: "Choose what it may do without asking", menu: true),
        AgentCommand(name: "compact", detail: "Summarize the conversation to free up context"),
        AgentCommand(name: "diff", detail: "Show the changes, untracked files too"),
        AgentCommand(name: "init", detail: "Write an AGENTS.md for this project"),
        AgentCommand(name: "mcp", detail: "List the MCP tools"),
        AgentCommand(name: "mention", detail: "Mention a file", menu: true),
        AgentCommand(name: "model", detail: "Pick the model and its reasoning", menu: true),
        AgentCommand(name: "new", detail: "Start a new conversation"),
        AgentCommand(name: "review", detail: "Review the changes", menu: true),
        AgentCommand(name: "status", detail: "Show the session's settings and usage"),
    ]
}
