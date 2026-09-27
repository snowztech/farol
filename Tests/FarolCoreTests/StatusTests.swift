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
    try StatusClient.send(StatusMessage(pane: "pane-1", status: .waiting), to: box.server.path)
    #expect(box.messages(count: 1) == [StatusMessage(pane: "pane-1", status: .waiting)])
}

@Test func deliversAClear() throws {
    let box = try Listening()
    try StatusClient.send(StatusMessage(pane: "pane-2", status: nil), to: box.server.path)
    #expect(box.messages(count: 1) == [StatusMessage(pane: "pane-2", status: nil)])
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
    let payload = "not json\n{\"pane\":\"p3\",\"status\":\"done\"}\n"
    _ = payload.withCString { write(fd, $0, strlen($0)) }
    close(fd)
    #expect(box.messages(count: 1) == [StatusMessage(pane: "p3", status: .done)])
}

@Test func socketIsPrivate() throws {
    let box = try Listening()
    let attributes = try FileManager.default.attributesOfItem(atPath: box.server.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
}

@Test func sendingWithoutAServerFails() {
    #expect(throws: (any Error).self) {
        try StatusClient.send(StatusMessage(pane: "x", status: .working), to: "/tmp/farol-nobody-\(UUID().uuidString.prefix(8)).sock")
    }
}
