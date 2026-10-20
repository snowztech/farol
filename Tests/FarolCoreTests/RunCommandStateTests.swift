import Foundation
import Testing
@testable import FarolCore

@Test func launchKeepsStopVisibleUntilTheCommandCanStart() {
    let start = Date(timeIntervalSince1970: 100)
    var state = RunCommandState(startedAt: start)
    let beforeLaunch = state.observe(runsProgram: false, at: start.addingTimeInterval(0.1))
    let running = state.observe(runsProgram: true, at: start.addingTimeInterval(0.5))
    let ended = state.observe(runsProgram: false, at: start.addingTimeInterval(1))
    #expect(beforeLaunch)
    #expect(running)
    #expect(!ended)
}

@Test func aCommandThatNeverStartsStopsShowingAfterTheStartupWindow() {
    let start = Date(timeIntervalSince1970: 100)
    var state = RunCommandState(startedAt: start)
    let expired = state.observe(runsProgram: false, at: start.addingTimeInterval(10))
    #expect(!expired)
}
