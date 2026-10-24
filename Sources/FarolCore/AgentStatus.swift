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
    /// What you just asked the agent, from Claude Code's `UserPromptSubmit`. Shown until its log has it.
    public var prompt: String?

    public init(pane: String, event: AgentEvent, conversation: AgentConversation? = nil, request: AgentRequest? = nil, prompt: String? = nil) {
        self.pane = pane
        self.event = event
        self.conversation = conversation
        self.request = request
        self.prompt = prompt
    }

    /// The words of a prompt hook's input. Nil for any other hook.
    public static func prompt(hookInput: Data) -> String? {
        guard let input = (try? JSONSerialization.jsonObject(with: hookInput)) as? [String: Any],
              input["hook_event_name"] as? String == "UserPromptSubmit",
              let prompt = (input["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else { return nil }
        return prompt
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

extension AgentRequest {
    /// One line for a notification: the question and its answers, or the tool and what it would do, cut to fit.
    public func summary(limit: Int = 180) -> String {
        let line = tool.map { "\($0) · \(title)" }
            ?? (choices.isEmpty ? title : title + " " + choices.map(\.label).joined(separator: " · "))
        return line.count <= limit ? line : String(line.prefix(limit - 1)) + "…"
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
    /// A question the agent is blocked on. The connection stays open until it is answered.
    public var onAsk: ((AskMessage, HeldConnection) -> Void)?
    /// A `farol` command run by an agent or a person, answered once on the same connection.
    public var onControl: ((ControlRequest, HeldConnection) -> Void)?

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
        // A client that went away mid-answer must not take Farol down with a broken pipe.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        // Messages are a few dozen bytes, so a small cap keeps a misbehaving client from holding memory.
        // A question's client waits for the answer without closing, so a line is read up to its newline.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < 64 * 1024 {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if buffer[0..<count].contains(UInt8(ascii: "\n")) { break }
        }
        let lines = data.split(separator: UInt8(ascii: "\n"))

        if let line = lines.first, let ask = try? JSONDecoder().decode(AskMessage.self, from: Data(line)) {
            let connection = HeldConnection(descriptor: client, deliverOn: delivery)
            delivery.async { [weak self] in
                if let handler = self?.onAsk { handler(ask, connection) } else { connection.reply(AskReply()) }
            }
            return
        }
        if let line = lines.first, let request = try? JSONDecoder().decode(ControlRequest.self, from: Data(line)) {
            let connection = HeldConnection(descriptor: client, deliverOn: delivery)
            delivery.async { [weak self] in
                if let handler = self?.onControl { handler(request, connection) } else { connection.reply(ControlReply.failed("Farol is not ready yet.")) }
            }
            return
        }
        close(client)
        for line in lines {
            guard let message = try? JSONDecoder().decode(StatusMessage.self, from: Data(line)) else { continue }
            delivery.async { [weak self] in self?.onMessage?(message) }
        }
    }
}

/// The open end of a request, like a question or a `farol` command, answered once.
/// Closing a question without answers sends the agent back to its own prompt.
public final class HeldConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let delivery: DispatchQueue
    private let lock = NSLock()
    private var finished = false
    private var watcher: DispatchSourceRead?

    init(descriptor: Int32, deliverOn delivery: DispatchQueue) {
        self.descriptor = descriptor
        self.delivery = delivery
    }

    /// A connection let go without an answer closes, so the hook falls back to the terminal instead of waiting forever.
    deinit {
        if !finished { close() }
    }

    /// Calls `onClose` if the hook goes away first, for instance because it was answered in the terminal.
    public func watch(_ onClose: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "dev.farol.ask"))
        source.setEventHandler { [weak self] in
            var byte: UInt8 = 0
            // The hook sends nothing after its question, so anything readable is the end of the connection.
            guard let self, read(self.descriptor, &byte, 1) <= 0, self.finish() else { return }
            self.delivery.async(execute: onClose)
        }
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
        watcher = source
        source.resume()
    }

    public func reply<Reply: Encodable>(_ reply: Reply) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        // Written under the lock, so a hook that left at the same moment can't leave us writing to a closed descriptor.
        if var line = try? JSONEncoder().encode(reply) {
            line.append(UInt8(ascii: "\n"))
            _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        }
        close()
    }

    /// True the first time only, which is when the descriptor is closed.
    private func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        close()
        return true
    }

    /// With the lock held.
    private func close() {
        finished = true
        if let watcher { watcher.cancel() } else { Darwin.close(descriptor) }
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

extension StatusClient {
    /// Sends a question and waits as long as it takes for the answer. Nil when Farol closes without one.
    public static func ask(_ message: AskMessage, to path: String) throws -> AskReply? {
        try request(message, as: AskReply.self, to: path)
    }

    /// Sends a `farol` command and waits for Farol's answer, which can be a long list or a long message.
    public static func control(_ request: ControlRequest, to path: String) throws -> ControlReply? {
        try self.request(request, as: ControlReply.self, to: path, limit: 8 << 20)
    }

    /// One line out, then the first line back, decoded. Nil when Farol closes without answering.
    static func request<Message: Encodable, Reply: Decodable>(_ message: Message, as: Reply.Type, to path: String, limit: Int = 64 * 1024) throws -> Reply? {
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
        guard line.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == line.count else { throw posixError("write") }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if buffer[0..<count].contains(UInt8(ascii: "\n")) { break }
        }
        return data.split(separator: UInt8(ascii: "\n")).first.flatMap { try? JSONDecoder().decode(Reply.self, from: Data($0)) }
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
