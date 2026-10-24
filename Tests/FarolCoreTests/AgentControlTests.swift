import Foundation
import Testing
@testable import FarolCore

private let sessions = [
    SessionInfo(id: "8F3A12C4-0000-0000-0000-000000000001", name: "farol", folder: "/Users/me/dev/farol", agent: "claude", status: .working, isCaller: true),
    SessionInfo(id: "8F3B99D0-0000-0000-0000-000000000002", name: "Add fuzzy search", folder: "/Users/me/dev/shelf", agent: "codex", status: .waiting,
                asking: "Allow touch probe.txt?"),
    SessionInfo(id: "1C0FFEE0-0000-0000-0000-000000000003", name: "play", folder: "/tmp/play", status: .idle),
    SessionInfo(id: "2D0FFEE0-0000-0000-0000-000000000004", name: "play", folder: "/tmp/play", status: .idle),
]

@Test func answersACommandOverTheSocket() throws {
    let path = "/tmp/farol-control-\(UUID().uuidString.prefix(8))"
    let server = StatusServer(path: path, deliverOn: DispatchQueue(label: "test.delivery"))
    server.onControl = { request, connection in
        #expect(request == ControlRequest(pane: "pane-1", action: .sessions))
        connection.reply(ControlReply(sessions: sessions))
    }
    try server.start()
    defer { server.stop() }
    let reply = try StatusClient.control(ControlRequest(pane: "pane-1", action: .sessions), to: path)
    #expect(reply?.sessions == sessions)
}

@Test func aStatusReportIsNotACommand() throws {
    let line = try JSONEncoder().encode(StatusMessage(pane: "p", event: .working))
    #expect((try? JSONDecoder().decode(ControlRequest.self, from: line)) == nil)
}

@Test func findsASessionByItsIDOrName() throws {
    #expect(try SessionInfo.find("8f3b", in: sessions).get().name == "Add fuzzy search")
    #expect(try SessionInfo.find("add fuzzy search", in: sessions).get().shortID == "8f3b99d0")
    #expect(SessionInfo.find("8f3", in: sessions) == .failure(.noSession("8f3")), "too short to be an id")
    #expect(SessionInfo.find("8f3", in: sessions).failureDescription == "No session is called 8f3. `farol sessions` lists them.")
    #expect(SessionInfo.find("8f3a1", in: sessions) == .success(sessions[0]))
    #expect(SessionInfo.find("play", in: sessions) == .failure(.sameName("play", ["1c0ffee0", "2d0ffee0"])))
}

@Test func aWaitEndsOnceTheAgentNeedsSomeoneOrStops() {
    func ends(_ status: SessionInfo.Status, afterWorking worked: Bool) -> Bool {
        SessionInfo(id: "x", name: "x", folder: "/", status: status).endsWait(afterWorking: worked)
    }
    #expect(ends(.waiting, afterWorking: false) && ends(.done, afterWorking: false) && ends(.stopped, afterWorking: false))
    #expect(!ends(.working, afterWorking: true))
    #expect(!ends(.idle, afterWorking: false), "a task whose agent is still starting has not begun")
    #expect(ends(.idle, afterWorking: true), "its agent ended")
}

@Test func aTaskGetsABranchNobodyHas() {
    let taken: Set = ["add-fuzzy-search", "add-fuzzy-search-2"]
    #expect(NewTask.freeBranch(for: "Add fuzzy search", taken: taken.contains) == "add-fuzzy-search-3")
    #expect(NewTask.freeBranch(for: "Fix the login bug", taken: taken.contains) == "fix-the-login-bug")
    #expect(NewTask.freeBranch(for: "!!!", taken: { _ in false }) == "task")
}

@Test func printsALinePerSession() {
    #expect(ControlOutput.lines(Array(sessions.prefix(2))) == """
    8f3a12c4  working  farol  claude  (you)
    8f3b99d0  waiting  Add fuzzy search  codex
        asks: Allow touch probe.txt?
    """)
}

private extension Result where Failure == ControlError {
    var failureDescription: String? {
        if case .failure(let error) = self { return error.description }
        return nil
    }
}

@Test func readsACommandWithoutQuotes() throws {
    #expect(try ControlCommand.parse(["task", "fix", "the", "login", "bug", "--agent", "codex"]).get()
        == ControlCommand(action: .task(text: "fix the login bug", repo: nil, agent: "codex"), json: false))
    #expect(try ControlCommand.parse(["send", "8f3b", "run", "the", "tests"]).get().action == .send(session: "8f3b", text: "run the tests"))
    #expect(try ControlCommand.parse(["wait", "8f3b", "--timeout", "30", "--json"]).get() == ControlCommand(action: .wait(session: "8f3b", timeout: 30), json: true))
    #expect(try ControlCommand.parse(["wait", "8f3b"]).get().action == .wait(session: "8f3b", timeout: ControlCommand.waitLimit))
    #expect(try ControlCommand.parse(["sessions", "--json"]).get() == ControlCommand(action: .sessions, json: true))
}

@Test func saysWhatAWrongCommandLacks() {
    #expect(ControlCommand.parse(["task"]) == .failure(ControlUsage("Say what the task is: farol task fix the login bug")))
    #expect(ControlCommand.parse(["send", "8f3b"]) == .failure(ControlUsage("Say which session and what to send: farol send 8f3b99d0 run the tests")))
    #expect(ControlCommand.parse(["wait", "8f3b", "--timeout", "soon"]) == .failure(ControlUsage("--timeout takes a number of seconds.")))
    #expect(ControlCommand.parse(["task", "x", "--agent"]) == .failure(ControlUsage("--agent needs a value.")))
}
