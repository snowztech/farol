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

    /// Terminal notifications only, see CodexNotifications. Connecting also clears the hooks Farol 0.6 added.
    static func codex(config: URL = CodexNotifications.file, oldHooks: AgentHooks = .codex) -> AgentSetup {
        let hasOldHooks = { (try? oldHooks.read()).map(oldHooks.hasAnyFarolHook) == true }
        let edit = { (change: (String) throws -> String) in
            let text = try CodexNotifications.read(config)
            let changed = try change(text)
            if changed != text { try CodexNotifications.write(changed, to: config) }
        }
        return AgentSetup(
            name: "Codex",
            file: config,
            summaryWhenDisconnected: "Get told when Codex needs you or finishes.",
            summaryWhenConnected: "Farol tells you when Codex needs you or finishes. Codex doesn't report while it works, so the sidebar shows no working dot.",
            connectMessage: "Farol turns on Codex's terminal notifications in \(tilde(config)), on lines marked as added by Farol. The rest of the file stays as it is, and the current one is kept as \(backup(config)). Codex sessions that are already open need a restart.",
            disconnectMessage: "Farol stops notifying you when Codex needs you or finishes. Codex keeps working as before. Farol removes only the lines it added to \(tilde(config)) and keeps a backup.",
            state: {
                if hasOldHooks() { return .outdated }
                return (try? CodexNotifications.read(config)).map(CodexNotifications.isEnabled) == true ? .connected : .disconnected
            },
            connect: {
                try edit(CodexNotifications.enable)
                if hasOldHooks() { try oldHooks.write(oldHooks.remove(from: oldHooks.read())) }
            },
            disconnect: { try edit(CodexNotifications.disable) })
    }

    private static func tilde(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private static func backup(_ url: URL) -> String {
        url.lastPathComponent + ".farol-backup"
    }
}
