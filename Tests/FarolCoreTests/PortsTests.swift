import Darwin
import Foundation
import Testing
@testable import FarolCore

@Test func aSessionOwnsEverythingItsPanesStarted() {
    // 10 is a pane's login, 11 its shell, 12 an agent, 13 a dev server the agent started. 20 belongs to another pane.
    let parents: [pid_t: pid_t] = [10: 1, 11: 10, 12: 11, 13: 12, 20: 1, 21: 20]
    #expect(Ports.descendants(of: [10], parents: parents) == [10, 11, 12, 13])
    #expect(Ports.descendants(of: [99], parents: parents).isEmpty)
}

@Test func readsTheListeningSockets() {
    let output = "p13\nf20\nn*:3000\nf21\nn[::1]:3000\nf22\nn127.0.0.1:5173\np40\nf9\nn*:7000\n"
    #expect(Ports.sockets(fromLsof: output) == [.init(pid: 13, port: 3000), .init(pid: 13, port: 5173), .init(pid: 40, port: 7000)])
}

@Test func leavesOutThePortsAgentsPickForThemselves() {
    // Codex listening on a port macOS picked, next to the dev server it started.
    let output = "p12\nf8\nn127.0.0.1:55150\np13\nf20\nn*:3000\n"
    #expect(Ports.sockets(fromLsof: output) == [.init(pid: 13, port: 3000)])
}

@Test func keepsOnlyThePortsThatServePages() throws {
    #expect(Ports.servesPages(try answering("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")) == true)
    #expect(Ports.servesPages(try answering("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")) == true)
    // A bare websocket, like Vite's hot reload.
    #expect(Ports.servesPages(try answering("HTTP/1.1 426 Upgrade Required\r\nContent-Length: 0\r\n\r\n")) == false)
    // Redis turning down an HTTP request.
    #expect(Ports.servesPages(try answering("-ERR unknown command\r\n")) == false)
}

/// A server on a free port that answers its first connection with `reply`, then closes.
private func answering(_ reply: String) throws -> Int {
    let server = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(server, $0, length) == 0 && listen(server, 1) == 0 && getsockname(server, $0, &length) == 0
        }
    }
    try #require(bound)
    Thread.detachNewThread {
        let client = accept(server, nil, nil)
        var request = [UInt8](repeating: 0, count: 1024)
        _ = read(client, &request, request.count)
        _ = reply.withCString { write(client, $0, strlen($0)) }
        close(client)
        close(server)
    }
    return Int(UInt16(bigEndian: address.sin_port))
}
