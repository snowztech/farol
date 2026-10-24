import Foundation

/// What an agent asks of Farol with `farol sessions`, `task`, `send`, `wait` and `read`, over the socket `farol status` uses.
/// One request a connection, answered once, like a question the agent's hook holds.
public struct ControlRequest: Codable, Equatable, Sendable {
    /// The pane the command ran in, so Farol knows which session asks. Nil outside a Farol pane.
    public var pane: String?
    public var action: Action

    public enum Action: Codable, Equatable, Sendable {
        case sessions
        /// An agent on `text` in a new worktree of `repo`, the caller's repository when nil. `agent` names a kind or a config folder.
        case task(text: String, repo: String?, agent: String?)
        case send(session: String, text: String)
        /// Answered once the session needs someone or is done, or after `timeout` seconds with how it is then.
        case wait(session: String, timeout: TimeInterval)
        case read(session: String)
    }

    public init(pane: String?, action: Action) {
        self.pane = pane
        self.action = action
    }
}

/// Farol's answer. `error` is in words for the agent to pass on, like where to turn a setting on.
public struct ControlReply: Codable, Equatable, Sendable {
    public var sessions: [SessionInfo]?
    /// The session a task started, or the one waited on, as it is now.
    public var session: SessionInfo?
    /// What `read` found: the agent's last message.
    public var text: String?
    /// Why a wait ended before the session needed someone or was done, in words for the agent.
    public var note: String?
    public var error: String?

    public init(sessions: [SessionInfo]? = nil, session: SessionInfo? = nil, text: String? = nil, note: String? = nil, error: String? = nil) {
        self.sessions = sessions
        self.session = session
        self.text = text
        self.note = note
        self.error = error
    }

    public static func failed(_ error: String) -> ControlReply { ControlReply(error: error) }
}

/// A session as an agent sees it: one pane, by the same id the phone uses.
public struct SessionInfo: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case idle, working, waiting, done, stopped
    }

    public var id: String
    public var name: String
    public var folder: String
    public var branch: String?
    /// The agent running there, like "claude" or "codex". Nil for a shell or a program Farol does not know.
    public var agent: String?
    public var status: Status
    /// What it waits on, in one line, when it does.
    public var asking: String?
    /// The pane the request came from.
    public var isCaller: Bool

    public init(id: String, name: String, folder: String, branch: String? = nil, agent: String? = nil, status: Status,
                asking: String? = nil, isCaller: Bool = false) {
        self.id = id
        self.name = name
        self.folder = folder
        self.branch = branch
        self.agent = agent
        self.status = status
        self.asking = asking
        self.isCaller = isCaller
    }

    /// How a session is named on the command line, short enough to type.
    public var shortID: String { String(id.prefix(8)).lowercased() }
}

extension SessionInfo {
    /// The session `name` means: an id or the start of one, or a session's name. A name two sessions share, or none has, is an error that says so.
    public static func find(_ name: String, in sessions: [SessionInfo]) -> Result<SessionInfo, ControlError> {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return .failure(.noSession(name)) }
        let byID = wanted.count >= 4 ? sessions.filter { $0.id.lowercased().hasPrefix(wanted) } : []
        let byName = sessions.filter { $0.name.lowercased() == wanted }
        let found = byID.isEmpty ? byName : byID
        switch found.count {
        case 1: return .success(found[0])
        case 0: return .failure(.noSession(name))
        default: return .failure(.sameName(name, found.map(\.shortID)))
        }
    }

    /// A wait is over once the agent needs someone, is done, or stopped working.
    /// A session that has not worked yet, like a task whose agent is still starting, has not begun.
    public func endsWait(afterWorking worked: Bool) -> Bool {
        switch status {
        case .waiting, .done, .stopped: true
        case .idle: worked
        case .working: false
        }
    }
}

public enum ControlError: Error, Equatable, CustomStringConvertible {
    case noSession(String)
    case sameName(String, [String])

    public var description: String {
        switch self {
        case .noSession(let name): "No session is called \(name). `farol sessions` lists them."
        case .sameName(let name, let ids): "More than one session is called \(name). Use one of their ids: \(ids.joined(separator: ", "))."
        }
    }
}

extension NewTask {
    /// A branch for a task that no branch or worktree has yet, so a task never lands on someone else's work.
    public static func freeBranch(for task: String, taken: (String) -> Bool) -> String {
        let base = branchName(for: task).isEmpty ? "task" : branchName(for: task)
        guard taken(base) else { return base }
        return (2...).lazy.map { "\(base)-\($0)" }.first { !taken($0) }!
    }
}

/// How the CLI prints replies: a line per session for reading, or the reply as JSON for a program.
public enum ControlOutput {
    public static func lines(_ sessions: [SessionInfo]) -> String {
        sessions.map(line).joined(separator: "\n")
    }

    public static func line(_ session: SessionInfo) -> String {
        var parts = [session.shortID, session.status.rawValue, session.name]
        if let agent = session.agent { parts.append(agent) }
        if let branch = session.branch { parts.append(branch) }
        if session.isCaller { parts.append("(you)") }
        var line = parts.joined(separator: "  ")
        if let asking = session.asking { line += "\n    asks: \(asking)" }
        return line
    }

    public static func json<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// A `farol` command an agent or a person types, read from its arguments.
/// Words after the command need no quotes, so `farol task fix the login bug --agent codex` is a task about fixing the login bug.
public struct ControlCommand: Equatable, Sendable {
    public var action: ControlRequest.Action
    /// The reply as JSON, for a program to read.
    public var json: Bool

    public static let names: Set = ["sessions", "task", "send", "wait", "read"]
    /// How long `wait` waits by default: under the ten minutes an agent's own command may take.
    public static let waitLimit: TimeInterval = 540

    public static func parse(_ arguments: [String]) -> Result<ControlCommand, ControlUsage> {
        guard let name = arguments.first, names.contains(name) else { return .failure(ControlUsage("Unknown command.")) }
        var words: [String] = []
        var options: [String: String] = [:]
        var json = false
        var rest = arguments.dropFirst()[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--json": json = true
            case "--agent", "--repo", "--timeout":
                guard let value = rest.popFirst() else { return .failure(ControlUsage("\(argument) needs a value.")) }
                options[argument] = value
            default: words.append(argument)
            }
        }
        let text = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let action: ControlRequest.Action
        switch name {
        case "sessions":
            action = .sessions
        case "task":
            guard !text.isEmpty else { return .failure(ControlUsage("Say what the task is: farol task fix the login bug")) }
            action = .task(text: text, repo: options["--repo"], agent: options["--agent"])
        case "send":
            guard let session = words.first, case let message = words.dropFirst().joined(separator: " "), !message.isEmpty else {
                return .failure(ControlUsage("Say which session and what to send: farol send 8f3b99d0 run the tests"))
            }
            action = .send(session: session, text: message)
        case "wait":
            guard let session = words.first else { return .failure(ControlUsage("Say which session to wait for: farol wait 8f3b99d0")) }
            guard let timeout = options["--timeout"].map(TimeInterval.init) ?? waitLimit, timeout > 0 else {
                return .failure(ControlUsage("--timeout takes a number of seconds."))
            }
            action = .wait(session: session, timeout: timeout)
        default:
            guard let session = words.first else { return .failure(ControlUsage("Say which session to read: farol read 8f3b99d0")) }
            action = .read(session: session)
        }
        return .success(ControlCommand(action: action, json: json))
    }
}

public struct ControlUsage: Error, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}
