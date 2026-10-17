import Testing
@testable import FarolCore

private func status(after events: [AgentEvent]) -> AgentStatus? {
    var activity = AgentActivity()
    events.forEach { activity.apply($0) }
    return activity.status
}

@Test func followsTheMainAgent() {
    #expect(status(after: []) == nil)
    #expect(status(after: [.working]) == .working)
    #expect(status(after: [.working, .waiting]) == .waiting)
    #expect(status(after: [.working, .done]) == .done)
    #expect(status(after: [.working, .done, .clear]) == nil)
}

@Test func aForegroundSubagentChangesNothing() {
    #expect(status(after: [.working, .subagentStart, .working, .subagentStop, .done]) == .done)
}

/// Claude ends its turn while a background agent keeps going. The pane stays working until that agent stops.
@Test func aBackgroundSubagentKeepsThePaneWorking() {
    let handedOff: [AgentEvent] = [.working, .subagentStart, .done]
    #expect(status(after: handedOff) == .working)
    #expect(status(after: handedOff + [.working]) == .working)
    #expect(status(after: handedOff + [.subagentStop]) == .done)
    #expect(status(after: handedOff + [.subagentStop, .working, .done]) == .done)
}

@Test func waitingWinsOverARunningSubagent() {
    #expect(status(after: [.working, .subagentStart, .waiting]) == .waiting)
}

@Test func aMissedStopCantGoBelowZeroOrOutliveTheSession() {
    #expect(status(after: [.subagentStop, .subagentStop, .working, .done]) == .done)
    #expect(status(after: [.subagentStart, .clear, .working, .done]) == .done)
}

@Test func acknowledgingClearsOnlyAFinishedTurn() {
    var activity = AgentActivity()
    [.working, .done].forEach { activity.apply($0) }
    activity.acknowledge()
    #expect(activity.status == nil)

    [.working, .subagentStart, .done].forEach { activity.apply($0) }
    activity.acknowledge()
    #expect(activity.status == .working)
}

@Test func anAgentStartingClearsWhatWasShown() {
    var activity = AgentActivity()
    activity.apply(.done)
    activity.apply(.subagentStart)
    activity.apply(.start)
    #expect(activity.status == nil)
}

/// Claude Code rings when a question waits. Answered from a phone, that bell must not keep the session waiting.
@Test func anAgentThatReportsItselfIsToldFromOneThatOnlyRings() {
    var activity = AgentActivity()
    #expect(!activity.reports)
    activity.apply(.start)
    #expect(activity.reports)
    activity.apply(.waiting)
    activity.apply(.done)
    #expect(activity.reports)
    activity.apply(.clear)
    #expect(!activity.reports, "a program after the agent ends rings for itself")
}

/// You stopped it. A background agent it handed off to still keeps the pane working.
@Test func aStopEndsTheMainAgentOnly() {
    var activity = AgentActivity()
    activity.apply(.waiting)
    #expect(activity.since != nil)
    activity.stop()
    #expect(activity.status == nil)
    activity.apply(.subagentStart)
    activity.apply(.working)
    activity.stop()
    #expect(activity.status == .working)
}
