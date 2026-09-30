import Foundation

/// One row in Settings → Agents: what Farol changes in an agent's config to hear from it, and how to undo it.
/// Adding an agent is one more value in `all`.
public struct AgentSetup {
    public enum State {
        case disconnected
        /// Set up by an older Farol, in a way that no longer works as well.
        case outdated
        case connected
    }

    public let name: String
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

    public static let all = [claude(), codex()]

    /// Hooks report working, waiting and done.
    static func claude(hooks: AgentHooks = .claude) -> AgentSetup {
        AgentSetup(
            name: hooks.name,
            file: hooks.file,
            summaryWhenDisconnected: "Show in the sidebar when Claude Code is working, waiting for you or done.",
            summaryWhenConnected: "The sidebar shows when Claude Code is working, waiting for you or done.",
            connectMessage: "Farol adds hooks for \(hooks.events.count) events to \(tilde(hooks.file)). Your other settings stay as they are, though the file may be reformatted. The current file is kept as \(backup(hooks.file)).",
            disconnectMessage: "The sidebar stops showing when Claude Code is working, waiting or done, and Farol stops notifying you. Claude Code keeps working as before. Farol removes only its own hooks from \(tilde(hooks.file)) and keeps a backup.",
            state: {
                guard let settings = try? hooks.read() else { return .disconnected }
                if hooks.isInstalled(in: settings) { return .connected }
                return hooks.hasAnyFarolHook(in: settings) ? .outdated : .disconnected
            },
            connect: { try hooks.write(hooks.install(into: hooks.read())) },
            disconnect: { try hooks.write(hooks.remove(from: hooks.read())) })
    }

    /// Interactive Codex reports through its title. Hooks cover non-interactive runs and background agents.
    static func codex(hooks: AgentHooks = .codex, legacyConfig: URL = CodexNotifications.file) -> AgentSetup {
        let hasLegacyNotifications = {
            (try? CodexNotifications.read(legacyConfig)).map(CodexNotifications.hasFarolSettings) == true
        }
        let edit = { (change: (String) throws -> String) in
            let text = try CodexNotifications.read(legacyConfig)
            let changed = try change(text)
            if changed != text { try CodexNotifications.write(changed, to: legacyConfig) }
        }
        return AgentSetup(
            name: "Codex",
            file: hooks.file,
            summaryWhenDisconnected: "Interactive Codex sessions already show status. Connect hooks for non-interactive runs and background agents.",
            summaryWhenConnected: "Codex sessions show when they are working, waiting for you or done, including non-interactive runs.",
            connectMessage: "Interactive Codex sessions report through their terminal title. Farol adds hooks for \(hooks.events.count) events to \(tilde(hooks.file)) for non-interactive runs and background agents. Your other settings stay as they are, though the file may be reformatted. The current file is kept as \(backup(hooks.file)). Codex sessions that are already open need a restart to use the hooks.",
            disconnectMessage: "Interactive Codex sessions keep showing status through their terminal title, but non-interactive runs and background agents stop reporting. Farol removes only its own hooks from \(tilde(hooks.file)) and keeps a backup.",
            state: {
                guard let settings = try? hooks.read() else { return .disconnected }
                if hooks.isInstalled(in: settings), !hasLegacyNotifications() { return .connected }
                return hooks.hasAnyFarolHook(in: settings) || hasLegacyNotifications() ? .outdated : .disconnected
            },
            connect: {
                try hooks.write(hooks.install(into: hooks.read()))
                try edit(CodexNotifications.disable)
            },
            disconnect: {
                try hooks.write(hooks.remove(from: hooks.read()))
                try edit(CodexNotifications.disable)
            })
    }

    private static func tilde(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private static func backup(_ url: URL) -> String {
        url.lastPathComponent + ".farol-backup"
    }
}
