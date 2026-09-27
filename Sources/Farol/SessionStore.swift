import AppKit
import GhosttyTerminal

final class Session: ObservableObject, Identifiable {
    enum Status {
        case running
        /// The program rang the bell or sent a notification while you were elsewhere.
        /// Agents like Claude Code do this when they wait for input.
        case needsAttention
    }

    let id = UUID()
    let terminal: TerminalView
    @Published var title = ""
    @Published var directory: String
    @Published var status = Status.running

    init(terminal: TerminalView, directory: String) {
        self.terminal = terminal
        self.directory = directory
    }

    /// Shells default to titles like "user@host:~/dir", which read worse than the folder name.
    /// Programs that set a real title (Claude Code, vim, htop) keep it.
    var displayName: String { hasProgramTitle ? title : folderName }

    /// Shown under a program title, so you still know where it runs.
    var subtitle: String? {
        guard hasProgramTitle else { return nil }
        let home = NSHomeDirectory()
        return directory.hasPrefix(home) ? "~" + directory.dropFirst(home.count) : directory
    }

    private var hasProgramTitle: Bool {
        !(title.isEmpty || title.contains("@") || title.hasPrefix("~") || title.hasPrefix("/"))
    }

    private var folderName: String {
        directory == NSHomeDirectory() ? "~" : (directory as NSString).lastPathComponent
    }
}

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var selectedID: UUID?

    private let runtime: TerminalRuntime
    /// Called when a session's terminal view is created, so the window can host it.
    var onSessionCreated: ((Session) -> Void)?
    var onSelectionChange: ((Session?) -> Void)?
    var onLastSessionClosed: (() -> Void)?

    init(runtime: TerminalRuntime) {
        self.runtime = runtime
    }

    var selected: Session? { sessions.first { $0.id == selectedID } }

    @discardableResult
    func create(directory: String = NSHomeDirectory()) -> Session {
        let terminal = TerminalView(runtime: runtime, workingDirectory: directory)
        let session = Session(terminal: terminal, directory: directory)

        terminal.onTitleChange = { [weak session] in session?.title = $0 }
        terminal.onWorkingDirectoryChange = { [weak session] in session?.directory = $0 }
        terminal.onBell = { [weak self, weak session] in self?.flag(session) }
        terminal.onNotification = { [weak self, weak session] _, _ in self?.flag(session) }
        terminal.onClose = { [weak self, weak session] in
            if let session { self?.close(session) }
        }

        sessions.append(session)
        onSessionCreated?(session)
        select(session)
        return session
    }

    func select(_ session: Session) {
        session.status = .running
        selectedID = session.id
        onSelectionChange?(session)
    }

    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        select(sessions[index])
    }

    func selectNext(offset: Int) {
        guard let current = sessions.firstIndex(where: { $0.id == selectedID }), !sessions.isEmpty else { return }
        select(index: (current + offset + sessions.count) % sessions.count)
    }

    /// Closing the last session ends the app: there is never a window without a terminal.
    func close(_ session: Session) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        if sessions.count == 1 {
            onLastSessionClosed?()
            return
        }
        session.terminal.removeFromSuperview()
        sessions.remove(at: index)
        if session.id == selectedID {
            select(sessions[min(index, sessions.count - 1)])
        }
    }

    private func flag(_ session: Session?) {
        guard let session, session.id != selectedID else { return }
        session.status = .needsAttention
    }
}
