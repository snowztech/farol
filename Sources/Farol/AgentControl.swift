import AppKit
import FarolCore
import GhosttyTerminal

/// Answers the `farol` commands agents run in their panes: the sessions as they are, a task started in a new worktree, a message typed to another agent, a wait until one needs someone, and an agent's last message.
/// Reading is always allowed. Starting tasks and sending messages need the setting, since one agent then acts on others.
final class AgentControl {
    private let store: SessionStore
    private let agents: AgentSettings
    private let worktrees: WorktreeSettings
    /// Waits not answered yet, each held on its own connection.
    private var waits: [Wait] = []
    private var checking: Timer?
    /// Panes told to do something, by a task or a message, and when. A wait on one counts only what their agent says after that.
    /// So neither an agent still starting nor the end of its turn before is taken for the answer.
    private var told: [UUID: Date] = [:]
    private let reading = DispatchQueue(label: "sh.farol.control.reading", qos: .userInitiated)

    private struct Wait {
        let pane: UUID
        /// When it began, or when the pane was told to do something before it.
        let since: Date
        /// The pane was told to do something, so only what its agent says after counts.
        let told: Bool
        let deadline: Date
        let connection: HeldConnection
    }

    init(store: SessionStore, agents: AgentSettings, worktrees: WorktreeSettings) {
        self.store = store
        self.agents = agents
        self.worktrees = worktrees
    }

    func handle(_ request: ControlRequest, _ connection: HeldConnection) {
        let caller = request.pane.flatMap(UUID.init(uuidString:))
        switch request.action {
        case .sessions:
            connection.reply(ControlReply(sessions: sessions(caller: caller)))
        case .task(let text, let repo, let agent):
            guard agents.agentControl else { return connection.reply(ControlReply.failed(Self.turnOn("start a task"))) }
            task(text, in: repo, with: agent, caller: caller, connection)
        case .send(let session, let text):
            guard agents.agentControl else { return connection.reply(ControlReply.failed(Self.turnOn("send a message to another session"))) }
            send(text, to: session, caller: caller, connection)
        case .wait(let session, let timeout):
            wait(for: session, timeout: timeout, caller: caller, connection)
        case .read(let session):
            read(session, caller: caller, connection)
        }
    }

    private static func turnOn(_ what: String) -> String {
        "Farol lets agents \(what) only when the user turns on Settings → Agents → Let agents start tasks and message sessions. Ask them to."
    }

    // MARK: Sessions

    /// Every pane, as the phone lists them, in the sidebar's order.
    private func sessions(caller: UUID?) -> [SessionInfo] {
        store.ordered.flatMap { session in session.panes.terminals.map { info(session, $0, caller: caller) } }
    }

    private func info(_ session: Session, _ terminal: TerminalView, caller: UUID?) -> SessionInfo {
        let status = SessionInfo.Status(rawValue: "\(session.status(of: terminal))") ?? .idle
        return SessionInfo(id: terminal.id.uuidString, name: session.label(of: terminal), folder: terminal.workingDirectory ?? session.directory,
                           branch: session.branch, agent: session.agent(in: terminal), status: status, asking: session.asking(in: terminal),
                           isCaller: terminal.id == caller)
    }

    /// The pane a command names, with its session, or a reply that says why there is none.
    private func target(_ name: String, caller: UUID?) -> Result<(Session, TerminalView), ControlError> {
        SessionInfo.find(name, in: sessions(caller: caller)).flatMap { found in
            for session in store.sessions {
                if let terminal = session.panes.terminals.first(where: { $0.id.uuidString == found.id }) { return .success((session, terminal)) }
            }
            return .failure(.noSession(name))
        }
    }

    // MARK: Task

    /// The caller's repository unless one is named, the caller's agent unless one is named, and a branch nobody has.
    private func task(_ text: String, in repo: String?, with agent: String?, caller: UUID?, _ connection: HeldConnection) {
        let calling = caller.flatMap { id in store.sessions.first { $0.panes.terminals.contains { $0.id == id } } }
        guard let directory = repo ?? calling.map({ $0.repoRoot ?? $0.directory }) else {
            return connection.reply(ControlReply.failed("Say which repository with --repo, since this command runs outside a Farol session."))
        }
        let callerAgent = calling.flatMap { session in session.panes.terminals.first { $0.id == caller }.flatMap(session.agent) }
        let folders = AgentFolder.find()
        let wanted = (agent ?? callerAgent)?.lowercased()
        guard let folder = folders.first(where: { [$0.kind.rawValue, $0.id.lowercased(), $0.label.lowercased()].contains(wanted) }) ?? (agent == nil ? folders.first : nil) else {
            return connection.reply(ControlReply.failed(agent.map { "No agent is called \($0). Use \(AgentFolder.Kind.allCases.map(\.rawValue).joined(separator: ", ")), connected in Settings → Agents." }
                ?? "Connect an agent in Settings → Agents first."))
        }
        // Opened beside the one on screen, so an agent's task never takes the window from you.
        store.startTask(text, in: directory, with: folder, copyEnvironmentFiles: worktrees.copyEnvironmentFiles, select: false) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (session, branch)):
                let pane = session.panes.focused
                told[pane.id] = .now
                var started = info(session, pane, caller: caller)
                started.branch = started.branch ?? branch
                connection.reply(ControlReply(session: started))
            case .failure(let error):
                connection.reply(ControlReply.failed("Farol could not start the task: \(error)"))
            }
        }
    }

    // MARK: Send

    /// Typed as the phone types a reply: pasted whole, then Return once the agent has taken it in.
    /// Never into a session waiting on someone, where it would answer a menu or a question nobody read.
    private func send(_ text: String, to name: String, caller: UUID?, _ connection: HeldConnection) {
        switch target(name, caller: caller) {
        case .failure(let error):
            connection.reply(ControlReply.failed(error.description))
        case .success(let (session, terminal)):
            guard terminal.id != caller else { return connection.reply(ControlReply.failed("That is your own session.")) }
            guard session.status(of: terminal) != .waiting else {
                return connection.reply(ControlReply.failed("\(session.label(of: terminal)) is waiting for someone to answer it. Ask the user, or wait for it."))
            }
            terminal.pasteText(text)
            told[terminal.id] = .now
            DispatchQueue.main.asyncAfter(deadline: .now() + RemoteTyping.returnDelay(afterPasteOf: text, elapsed: 0)) { [weak terminal] in
                terminal?.press(.enter)
            }
            connection.reply(ControlReply(session: info(session, terminal, caller: caller)))
        }
    }

    // MARK: Wait

    private func wait(for name: String, timeout: TimeInterval, caller: UUID?, _ connection: HeldConnection) {
        switch target(name, caller: caller) {
        case .failure(let error):
            connection.reply(ControlReply.failed(error.description))
        case .success(let (session, terminal)):
            let now = info(session, terminal, caller: caller)
            let toldAt = told[terminal.id]
            // A pane nobody told to do anything is answered as it is, unless it works. One told waits for its agent's answer.
            guard now.status == .working || toldAt != nil else { return connection.reply(ControlReply(session: now)) }
            waits.append(Wait(pane: terminal.id, since: toldAt ?? .now, told: toldAt != nil, deadline: .now + min(timeout, 3600), connection: connection))
            check()
        }
    }

    /// ponytail: looks every second while someone waits, and not at all otherwise. An agent's state reaching here as an event would answer sooner.
    private func check() {
        waits.removeAll { wait in
            guard let session = store.sessions.first(where: { $0.panes.terminals.contains { $0.id == wait.pane } }),
                  let terminal = session.panes.terminals.first(where: { $0.id == wait.pane }) else {
                wait.connection.reply(ControlReply.failed("That session was closed."))
                return true
            }
            let now = info(session, terminal, caller: nil)
            // It worked since when its agent said anything since, which a second's look could miss.
            let worked = (session.agents[wait.pane]?.since ?? .distantPast) > wait.since
            let ended = wait.told ? worked && now.endsWait(afterWorking: true) : now.endsWait(afterWorking: worked)
            guard ended || Date.now >= wait.deadline else { return false }
            if ended { told[wait.pane] = nil }
            wait.connection.reply(ControlReply(session: now, note: ended ? nil : Self.stillGoing(now, worked: worked)))
            return true
        }
        if waits.isEmpty {
            checking?.invalidate()
            checking = nil
        } else if checking == nil {
            checking = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        }
    }

    /// Why a wait ran out. An agent that never began is usually stopped at a question its terminal shows, like trusting a new folder.
    private static func stillGoing(_ session: SessionInfo, worked: Bool) -> String {
        guard session.status == .idle, !worked else { return "Still working. Run farol wait again to keep waiting." }
        return "Its agent has not started working. It may be asking something in its terminal, like whether to trust the new folder. Ask the user to look at \(session.name) in Farol."
    }

    // MARK: Read

    /// The agent's last message, from its own log, read off the main thread since a long log takes a moment.
    private func read(_ name: String, caller: UUID?, _ connection: HeldConnection) {
        switch target(name, caller: caller) {
        case .failure(let error):
            connection.reply(ControlReply.failed(error.description))
        case .success(let (session, terminal)):
            guard let log = session.logs[terminal.id]?.log else {
                return connection.reply(ControlReply.failed("\(session.label(of: terminal)) has no agent conversation to read."))
            }
            reading.async {
                let transcript = Transcript(url: URL(fileURLWithPath: log))
                transcript.refresh()
                guard let last = transcript.messages.last(where: { $0.role == .agent }) else {
                    return connection.reply(ControlReply.failed("Its agent has not said anything yet."))
                }
                connection.reply(ControlReply(text: last.text))
            }
        }
    }
}
