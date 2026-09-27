import Foundation

/// What an agent in a pane is doing, as reported by its hooks through the `farol` command.
public enum AgentStatus: String, Codable, CaseIterable, Sendable {
    case working
    /// Blocked on the user: a permission prompt or a question.
    case waiting
    /// Finished its turn. Stays until the user looks at the session.
    case done
}

/// One report from `farol status`. A nil status clears the pane.
public struct StatusMessage: Codable, Equatable, Sendable {
    public var pane: String
    public var status: AgentStatus?

    public init(pane: String, status: AgentStatus?) {
        self.pane = pane
        self.status = status
    }
}

/// Listens on a Unix socket for status reports. Each client sends one JSON line and disconnects.
/// The socket is readable by the current user only.
public final class StatusServer {
    public let path: String
    public var onMessage: ((StatusMessage) -> Void)?

    private let delivery: DispatchQueue
    private let queue = DispatchQueue(label: "dev.farol.status")
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String, deliverOn delivery: DispatchQueue = .main) {
        self.path = path
        self.delivery = delivery
    }

    deinit { stop() }

    public func start() throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // A previous run may have left the file behind, and bind fails on an existing path.
        unlink(path)

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw posixError("socket") }
        var address = try unixAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw posixError("bind") }
        chmod(path, 0o600)
        guard listen(listener, 16) == 0 else { throw posixError("listen") }

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listener >= 0 { close(listener) }
        listener = -1
        unlink(path)
    }

    private func acceptClient() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        // Messages are a few dozen bytes, so a small cap keeps a misbehaving client from holding memory.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < 64 * 1024 {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let message = try? JSONDecoder().decode(StatusMessage.self, from: Data(line)) else { continue }
            delivery.async { [weak self] in self?.onMessage?(message) }
        }
    }
}

public enum StatusClient {
    public static func send(_ message: StatusMessage, to path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        defer { close(fd) }
        var address = try unixAddress(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw posixError("connect") }
        var line = try JSONEncoder().encode(message)
        line.append(UInt8(ascii: "\n"))
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

private func unixAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else {
        throw NSError(domain: "Farol", code: 1, userInfo: [NSLocalizedDescriptionKey: "Socket path is too long: \(path)"])
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    return address
}

private func posixError(_ call: String) -> Error {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(call): \(String(cString: strerror(errno)))"])
}
