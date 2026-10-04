import Foundation

/// One row in Settings → Agents: what Farol changes in an agent's config to hear from it, and how to undo it.
/// There is one per config folder found, so a second account is one more row.
public struct AgentSetup {
    public enum State {
        case disconnected
        /// Set up by an older Farol, in a way that no longer works as well.
        case outdated
        case connected
    }

    public let name: String
    public let id: String
    /// The file Connect and Disconnect change.
    public let file: URL
    public let summaryWhenDisconnected: String
    public let summaryWhenConnected: String
    /// What connecting changes, shown before it does.
    public let connectMessage: String
    /// What disconnecting takes away, first, then what changes on disk.
    public let disconnectMessage: String
    public let state: () -> State
    public let connect: () throws -> Void
    public let disconnect: () throws -> Void

    public static func all(folders: [AgentFolder] = AgentFolder.find()) -> [AgentSetup] {
        folders.map { folder in
            switch folder.kind {
            case .claude: claude(hooks: .claude(in: folder))
            case .codex: codex(config: folder.directory.appendingPathComponent("config.toml"), hooks: .codex(in: folder))
            }
        }
    }

    /// Hooks report working, waiting and done.
    /// Rewrites the skill of every connected agent when Farol's text has changed, so a reworded skill needs no click.
    public static func refreshSkills(of setups: [AgentSetup] = all()) {
        for setup in setups where setup.state() != .disconnected {
            let skill = AgentSkill(nextTo: setup.file)
            if !skill.isCurrent { try? skill.install() }
        }
    }

    static func claude(hooks: AgentHooks = .claude) -> AgentSetup {
        let skill = AgentSkill(nextTo: hooks.file)
        return AgentSetup(
            name: hooks.name,
            id: hooks.file.path,
            file: hooks.file,
            summaryWhenDisconnected: "Show in the sidebar when Claude Code is working, waiting for you or done.",
            summaryWhenConnected: "The sidebar shows when Claude Code is working, waiting for you or done.",
            connectMessage: "Farol adds hooks for \(hooks.events.count) events to \(tilde(hooks.file)), and a skill in \(tilde(skill.file.deletingLastPathComponent())) so Claude Code can change Farol's settings when you ask. Your other settings stay as they are, though the file may be reformatted. The current file is kept as \(backup(hooks.file)).",
            disconnectMessage: "The sidebar stops showing when Claude Code is working, waiting or done, and Farol stops notifying you. Claude Code keeps working as before. Farol removes only its own hooks from \(tilde(hooks.file)) and keeps a backup, and removes its skill.",
            state: {
                guard let settings = try? hooks.read() else { return .disconnected }
                if hooks.isInstalled(in: settings) { return .connected }
                return hooks.hasAnyFarolHook(in: settings) ? .outdated : .disconnected
            },
            connect: {
                try hooks.write(hooks.install(into: hooks.read()))
                try skill.install()
            },
            disconnect: {
                try hooks.write(hooks.remove(from: hooks.read()))
                try skill.remove()
            })
    }

    /// Interactive Codex reports through its title. Hooks cover non-interactive runs and background agents.
    static func codex(config legacyConfig: URL = CodexNotifications.file, hooks: AgentHooks = .codex) -> AgentSetup {
        let hasLegacyNotifications = {
            (try? CodexNotifications.read(legacyConfig)).map(CodexNotifications.hasFarolSettings) == true
        }
        let edit = { (change: (String) throws -> String) in
            let text = try CodexNotifications.read(legacyConfig)
            let changed = try change(text)
            if changed != text { try CodexNotifications.write(changed, to: legacyConfig) }
        }
        let skill = AgentSkill(nextTo: hooks.file)
        return AgentSetup(
            name: hooks.name,
            id: hooks.file.path,
            file: hooks.file,
            summaryWhenDisconnected: "Interactive Codex sessions already show status. Connect hooks for non-interactive runs and background agents.",
            summaryWhenConnected: "Codex sessions show when they are working, waiting for you or done, including non-interactive runs.",
            connectMessage: "Interactive Codex sessions report through their terminal title. Farol adds hooks for \(hooks.events.count) events to \(tilde(hooks.file)) for non-interactive runs and background agents, and a skill in \(tilde(skill.file.deletingLastPathComponent())) so Codex can change Farol's settings when you ask. Your other settings stay as they are, though the file may be reformatted. The current file is kept as \(backup(hooks.file)). Codex sessions that are already open need a restart to use the hooks.",
            disconnectMessage: "Interactive Codex sessions keep showing status through their terminal title, but non-interactive runs and background agents stop reporting. Farol removes only its own hooks from \(tilde(hooks.file)) and keeps a backup, and removes its skill.",
            state: {
                guard let settings = try? hooks.read() else { return .disconnected }
                if hooks.isInstalled(in: settings), !hasLegacyNotifications() { return .connected }
                return hooks.hasAnyFarolHook(in: settings) || hasLegacyNotifications() ? .outdated : .disconnected
            },
            connect: {
                try hooks.write(hooks.install(into: hooks.read()))
                try edit(CodexNotifications.disable)
                try skill.install()
            },
            disconnect: {
                try hooks.write(hooks.remove(from: hooks.read()))
                try edit(CodexNotifications.disable)
                try skill.remove()
            })
    }

    private static func tilde(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private static func backup(_ url: URL) -> String {
        url.lastPathComponent + ".farol-backup"
    }
}
