/// One agent activity event, reported by a hook or an interactive terminal title.
public enum AgentEvent: String, Codable, CaseIterable, Sendable {
    case working, waiting, done, clear
    case subagentStart = "subagent-start"
    case subagentStop = "subagent-stop"
}

/// One pane's agent, rebuilt from its activity events. The only place that decides what the sidebar dot shows.
/// An agent can end its turn while a background subagent keeps running, so counting them keeps the pane working.
public struct AgentActivity: Equatable, Sendable {
    /// What the main agent last reported. Nil before anything is reported, and after it's cleared or acknowledged.
    private var main: AgentStatus?
    private var subagents = 0

    public init() {}

    public var status: AgentStatus? {
        if main == .waiting { return .waiting }
        if main == .working || subagents > 0 { return .working }
        return main
    }

    public mutating func apply(_ event: AgentEvent) {
        switch event {
        case .working: main = .working
        case .waiting: main = .waiting
        case .done: main = .done
        // Also what makes a missed subagent stop harmless: the session ending resets the count.
        case .clear: self = AgentActivity()
        case .subagentStart: subagents += 1
        case .subagentStop: subagents = max(0, subagents - 1)
        }
    }

    /// Looking at the session is the acknowledgement, so a finished turn stops showing.
    public mutating func acknowledge() {
        if status == .done { main = nil }
    }
}
