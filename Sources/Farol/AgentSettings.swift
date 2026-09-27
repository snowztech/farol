import Foundation

/// Farol's own agent preferences. They live in UserDefaults because Ghostty's config file rejects keys it does not know.
final class AgentSettings: ObservableObject {
    private static let defaults = UserDefaults.standard

    @Published var notifyWaiting: Bool { didSet { Self.defaults.set(notifyWaiting, forKey: "agents.notifyWaiting") } }
    @Published var notifyDone: Bool { didSet { Self.defaults.set(notifyDone, forKey: "agents.notifyDone") } }
    @Published var dockBadge: Bool { didSet { Self.defaults.set(dockBadge, forKey: "agents.dockBadge") } }
    /// Typed into the shell of each new session, for example "claude". Empty starts a plain shell.
    @Published var startCommand: String { didSet { Self.defaults.set(startCommand, forKey: "agents.startCommand") } }

    init() {
        Self.defaults.register(defaults: [
            "agents.notifyWaiting": true, "agents.notifyDone": true, "agents.dockBadge": true,
        ])
        notifyWaiting = Self.defaults.bool(forKey: "agents.notifyWaiting")
        notifyDone = Self.defaults.bool(forKey: "agents.notifyDone")
        dockBadge = Self.defaults.bool(forKey: "agents.dockBadge")
        startCommand = Self.defaults.string(forKey: "agents.startCommand") ?? ""
    }
}
