import Foundation

/// Farol's own agent preferences. They live in UserDefaults because Ghostty's config file rejects keys it does not know.
final class AgentSettings: ObservableObject {
    private static let defaults = UserDefaults.standard

    @Published var notifyWaiting: Bool { didSet { Self.defaults.set(notifyWaiting, forKey: "agents.notifyWaiting") } }
    @Published var notifyDone: Bool { didSet { Self.defaults.set(notifyDone, forKey: "agents.notifyDone") } }
    @Published var dockBadge: Bool { didSet { Self.defaults.set(dockBadge, forKey: "agents.dockBadge") } }
    /// Off until turned on, like every feature that shows outside Farol's window.
    @Published var menuBarStatus: Bool { didSet { Self.defaults.set(menuBarStatus, forKey: "agents.menuBarStatus") } }
    /// Typed into the shell of each new session, for example "claude". Empty starts a plain shell.
    @Published var startCommand: String { didSet { Self.defaults.set(startCommand, forKey: "agents.startCommand") } }

    init() {
        Self.defaults.register(defaults: [
            "agents.notifyWaiting": true, "agents.notifyDone": true, "agents.dockBadge": true,
        ])
        notifyWaiting = Self.defaults.bool(forKey: "agents.notifyWaiting")
        notifyDone = Self.defaults.bool(forKey: "agents.notifyDone")
        dockBadge = Self.defaults.bool(forKey: "agents.dockBadge")
        menuBarStatus = Self.defaults.bool(forKey: "agents.menuBarStatus")
        startCommand = Self.defaults.string(forKey: "agents.startCommand") ?? ""
    }
}
