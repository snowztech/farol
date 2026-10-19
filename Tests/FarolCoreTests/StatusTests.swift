import Foundation
import Testing
@testable import FarolCore

/// A server on a fresh socket, collecting what it receives.
final class Listening {
    let server: StatusServer
    private var received: [StatusMessage] = []
    private let lock = NSLock()

    init() throws {
        // Short on purpose: Unix socket paths are limited to about 100 bytes.
        let path = "/tmp/farol-test-\(UUID().uuidString.prefix(8)).sock"
        server = StatusServer(path: path, deliverOn: DispatchQueue(label: "test"))
        server.onMessage = { [weak self] message in
            guard let self else { return }
            self.lock.lock()
            self.received.append(message)
            self.lock.unlock()
        }
        try server.start()
    }

    deinit { server.stop() }

    /// Waits up to a second for `count` messages.
    func messages(count: Int) -> [StatusMessage] {
        for _ in 0..<100 {
            lock.lock()
            let current = received
            lock.unlock()
            if current.count >= count { return current }
            usleep(10_000)
        }
        return received
    }
}

@Test func deliversAStatus() throws {
    let box = try Listening()
    try StatusClient.send(StatusMessage(pane: "pane-1", event: .waiting), to: box.server.path)
    #expect(box.messages(count: 1) == [StatusMessage(pane: "pane-1", event: .waiting)])
}

@Test func deliversAClear() throws {
    let box = try Listening()
    try StatusClient.send(StatusMessage(pane: "pane-2", event: .clear), to: box.server.path)
    #expect(box.messages(count: 1) == [StatusMessage(pane: "pane-2", event: .clear)])
}

@Test func skipsJunkAndKeepsValidLines() throws {
    let box = try Listening()
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        let bytes = Array(box.server.path.utf8)
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    let payload = "not json\n{\"pane\":\"p3\",\"event\":\"done\"}\n"
    _ = payload.withCString { write(fd, $0, strlen($0)) }
    close(fd)
    #expect(box.messages(count: 1) == [StatusMessage(pane: "p3", event: .done)])
}

@Test func socketIsPrivate() throws {
    let box = try Listening()
    let attributes = try FileManager.default.attributesOfItem(atPath: box.server.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
}

@Test func sendingWithoutAServerFails() {
    #expect(throws: (any Error).self) {
        try StatusClient.send(StatusMessage(pane: "x", event: .working), to: "/tmp/farol-nobody-\(UUID().uuidString.prefix(8)).sock")
    }
}

@Test func aPermissionRequestSaysWhatTheToolWouldDo() throws {
    let input = Data(#"{"hook_event_name":"PermissionRequest","cwd":"/Users/me/shelf","tool_use_id":"toolu_1","tool_name":"Bash","tool_input":{"command":"npm test -- --watch=false","description":"Run the tests"}}"#.utf8)
    let request = try #require(AgentRequest(hookInput: input))
    #expect(request.id == "toolu_1")
    #expect(request.tool == "Bash")
    #expect(request.title == "Run the tests")
    #expect(request.detail == "npm test -- --watch=false")
    #expect(request.choices.isEmpty)
}

@Test func aQuestionKeepsItsAnswersInOrder() throws {
    let input = Data(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database?","header":"Storage","options":[{"label":"SQLite","description":"One file"},{"label":"Postgres"}]}]}}"#.utf8)
    let request = try #require(AgentRequest(hookInput: input))
    #expect(request.tool == nil)
    #expect(request.title == "Which database?")
    #expect(request.choices == [AgentRequest.Choice(label: "SQLite", detail: "One file"), AgentRequest.Choice(label: "Postgres", detail: nil)])
}

@Test func aSummaryPutsTheAnswersAfterTheQuestion() throws {
    let question = Data(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database?","options":[{"label":"SQLite"},{"label":"Postgres"}]}]}}"#.utf8)
    #expect(try #require(AgentRequest(hookInput: question)).summary() == "Which database? SQLite · Postgres")
    let tool = Data(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"Clean the build"}}"#.utf8)
    #expect(try #require(AgentRequest(hookInput: tool)).summary() == "Bash · Clean the build")
    let long = try #require(AgentRequest(hookInput: tool)).summary(limit: 10)
    #expect(long.count == 10 && long.hasSuffix("…"))
}

@Test func onlyARequestOrASingleQuestionIsARequest() {
    let two = Data(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"A?"},{"question":"B?"}]}}"#.utf8)
    #expect(AgentRequest(hookInput: two) == nil)
    #expect(AgentRequest(hookInput: Data(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}"#.utf8)) == nil)
    #expect(AgentRequest(hookInput: Data(#"{"hook_event_name":"Notification","message":"Claude needs your permission"}"#.utf8)) == nil)
    #expect(AgentRequest(hookInput: Data("not json".utf8)) == nil)
}
