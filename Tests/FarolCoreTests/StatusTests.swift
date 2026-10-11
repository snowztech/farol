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

@Test func answersARequestOnTheSameConnection() throws {
    let box = try Listening()
    box.server.onRequest = { request in
        request == .read(session: 2) ? .text("➜  shelf git:(main)\n") : .refused("unexpected")
    }
    #expect(try StatusClient.ask(.read(session: 2), at: box.server.path) == .text("➜  shelf git:(main)\n"))
}

@Test func passesARefusalBack() throws {
    let box = try Listening()
    box.server.onRequest = { _ in .refused("Remote is off.") }
    #expect(try StatusClient.ask(.key(session: 1, key: .enter), at: box.server.path) == .refused("Remote is off."))
}

@Test func aRequestWithNobodyToAnswerIsRefused() throws {
    let box = try Listening()
    #expect(try StatusClient.ask(.sessions, at: box.server.path) == .refused("Farol has nothing to answer with."))
}

@Test func givesUpOnAnAppThatIsTooBusyAndNeverActsLate() throws {
    let busy = DispatchQueue(label: "busy")
    let server = StatusServer(path: "/tmp/farol-test-\(UUID().uuidString.prefix(8)).sock", deliverOn: busy)
    defer { server.stop() }
    let acted = NSLock()
    var count = 0
    server.onRequest = { _ in
        acted.lock(); count += 1; acted.unlock()
        return .text("")
    }
    try server.start()
    // Holds the queue the answer would come from for longer than the server waits.
    let release = DispatchSemaphore(value: 0)
    busy.async { release.wait() }
    #expect(try StatusClient.ask(.key(session: 1, key: .enter), at: server.path) == .refused("Farol did not answer in time."))
    release.signal()
    busy.sync {}
    acted.lock(); defer { acted.unlock() }
    #expect(count == 0)
}
