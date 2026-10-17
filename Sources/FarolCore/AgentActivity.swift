import Foundation

/// One agent activity event, reported by a hook or an interactive terminal title.
public enum AgentEvent: String, Codable, CaseIterable, Sendable {
    case working, waiting, done, clear
    /// An agent started in the pane, before it has said anything. It clears the dot as `clear` does, and says an agent is there.
    case start
    case subagentStart = "subagent-start"
    case subagentStop = "subagent-stop"
}

/// One pane's agent, rebuilt from its activity events. The only place that decides what the sidebar dot shows.
/// An agent can end its turn while a background subagent keeps running, so counting them keeps the pane working.
public struct AgentActivity: Equatable, Sendable {
    /// What the main agent last reported. Nil before anything is reported, and after it's cleared or acknowledged.
    private var main: AgentStatus?
    private var subagents = 0
    /// The agent says what it does, through hooks or its title, from its first report until it ends.
    /// Its bell or notification then says nothing more, like Claude Code's when a question waits, and it would outlast the answer.
    public private(set) var reports = false
    /// When the main agent last said what it does, to tell a stop written after it from one before.
    public private(set) var since: Date?

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
        case .clear, .start: self = AgentActivity()
        case .subagentStart: subagents += 1
        case .subagentStop: subagents = max(0, subagents - 1)
        }
        reports = event != .clear
        if event == .working || event == .waiting || event == .done { since = .now }
    }

    /// You stopped the agent, which Claude Code runs no hook for. A subagent left running still counts.
    public mutating func stop() {
        main = nil
    }

    /// Looking at the session is the acknowledgement, so a finished turn stops showing.
    public mutating func acknowledge() {
        if status == .done { main = nil }
    }
}
