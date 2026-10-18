import Darwin
import Testing
@testable import FarolCore

@Test func aSessionOwnsEverythingItsPanesStarted() {
    // 10 is a pane's login, 11 its shell, 12 an agent, 13 a dev server the agent started. 20 belongs to another pane.
    let parents: [pid_t: pid_t] = [10: 1, 11: 10, 12: 11, 13: 12, 20: 1, 21: 20]
    #expect(Ports.descendants(of: [10], parents: parents) == [10, 11, 12, 13])
    #expect(Ports.descendants(of: [99], parents: parents).isEmpty)
}

@Test func readsTheListeningPortsOfTheSessionsProcesses() {
    let output = "p13\nf20\nn*:3000\nf21\nn[::1]:3000\nf22\nn127.0.0.1:5173\np40\nf9\nn*:7000\n"
    #expect(Ports.ports(fromLsof: output, of: [13]) == [3000, 5173])
    #expect(Ports.ports(fromLsof: output, of: [12]).isEmpty)
}
