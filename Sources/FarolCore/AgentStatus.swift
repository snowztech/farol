import Foundation

/// What an agent in a pane is doing, as reported by hooks or an interactive terminal title.
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
    public var event: AgentEvent
    /// The agent's own conversation, when its hook says which: what a phone reads, and what a restored session resumes.
    public var conversation: AgentConversation?
    /// What a waiting agent asks, when its hook says.
    public var request: AgentRequest?

    public init(pane: String, event: AgentEvent, conversation: AgentConversation? = nil, request: AgentRequest? = nil) {
        self.pane = pane
        self.event = event
        self.conversation = conversation
        self.request = request
    }
}

/// What an agent waits on you for, from its hook rather than its screen: a tool it asks to run, or a question with its answers.
public struct AgentRequest: Codable, Equatable, Sendable {
    public var id: String
    /// The tool asking, like "Bash". Nil for a question.
    public var tool: String?
    /// The command, the file, or the question, in one line.
    public var title: String
    /// What the tool would do in full: a script, or an edit as a unified diff.
    public var detail: String?
    /// A question's answers, in the order the agent numbers them. Empty for a tool, whose answers only its screen shows.
    public var choices: [Choice]

    public struct Choice: Codable, Equatable, Sendable {
        public var label: String
        public var detail: String?
    }

    /// From Claude Code's or Codex's `PermissionRequest` input, or Claude Code's `PreToolUse` for `AskUserQuestion`. Nil for anything else.
    public init?(hookInput: Data) {
        guard let input = (try? JSONSerialization.jsonObject(with: hookInput)) as? [String: Any],
              let name = input["tool_name"] as? String else { return nil }
        let arguments = input["tool_input"] as? [String: Any] ?? [:]
        id = input["tool_use_id"] as? String ?? UUID().uuidString
        if name == "AskUserQuestion" {
            // Several questions are asked one after another on the same screen, which one request cannot follow.
            guard let questions = arguments["questions"] as? [[String: Any]], questions.count == 1,
                  let question = questions[0]["question"] as? String else { return nil }
            tool = nil
            title = question
            detail = nil
            choices = (questions[0]["options"] as? [[String: Any]] ?? []).compactMap { option in
                (option["label"] as? String).map { Choice(label: $0, detail: option["description"] as? String) }
            }
        } else if input["hook_event_name"] as? String == "PermissionRequest" {
            let call = ClaudeLog.tool(name, arguments, in: input["cwd"] as? String, id: id)
            tool = name
            title = call.text
            detail = call.detail
            choices = []
        } else {
            return nil
        }
    }
}

/// The conversation an agent keeps, as Claude Code's hooks name it on their input.
public struct AgentConversation: Codable, Equatable, Sendable {
    /// What `claude --resume` takes.
    public var id: String
    /// The file the agent logs the conversation to.
    public var log: String

    public init(id: String, log: String) {
        self.id = id
        self.log = log
    }

    /// From a hook's input, which Claude Code writes as JSON with `session_id` and `transcript_path`. Nil for anything else.
    public init?(hookInput: Data) {
        guard let input = (try? JSONSerialization.jsonObject(with: hookInput)) as? [String: Any],
              let id = input["session_id"] as? String, let log = input["transcript_path"] as? String, !id.isEmpty, !log.isEmpty else { return nil }
        self.init(id: id, log: log)
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
