import AppKit
import FarolCore
import GhosttyTerminal

final class Session: ObservableObject, Identifiable {
    enum Status {
        case running
        /// The program rang the bell or sent a notification while you were elsewhere.
        /// Agents like Claude Code do this when they wait for input.
        case needsAttention
    }

    let id = UUID()
    let panes: PaneContainer
    @Published var title = ""
    @Published var directory: String
    @Published var status = Status.running
    @Published private(set) var branch: String?
    @Published private(set) var repoName: String?
    /// Set when the session runs in one of Farol's worktrees, even after `cd` into a subfolder.
    let worktree: String?

    init(panes: PaneContainer, directory: String) {
        self.panes = panes
        self.directory = directory
        worktree = Worktrees.default.root(of: directory)
        refreshGit()
    }

    /// The name, folder and branch follow whichever pane has focus.
    func show(_ terminal: TerminalView) {
        title = terminal.title
        if let folder = terminal.workingDirectory { directory = folder }
        refreshGit()
    }

    var hasRunningProcess: Bool { panes.terminals.contains { $0.hasRunningProcess } }

    /// Looks up the branch off the main thread. The shell retitles at every prompt, so a `git checkout` shows up too.
    func refreshGit() {
        let directory = directory
        DispatchQueue.global(qos: .userInitiated).async {
            let branch = Git.branch(of: directory)
            let repo = Git.repoRoot(of: directory).map { URL(fileURLWithPath: $0).lastPathComponent }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.directory == directory else { return }
                self.branch = branch
                self.repoName = repo
            }
        }
    }

    /// Shells default to titles like "user@host:~/dir", which read worse than the folder name.
    /// Programs that set a real title (Claude Code, vim, htop) keep it.
    /// A worktree folder is named after its branch, so the repo name says more there.
    var displayName: String {
        if hasProgramTitle { return title }
        if worktree != nil, let repoName { return repoName }
        return folderName
    }

    /// The folder, when a program title took the name slot and there is no branch to show instead.
    var location: String? {
        guard hasProgramTitle, branch == nil else { return nil }
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
    /// A pane's shell exited. The window decides whether that closes a pane or the whole session.
    var onPaneExit: ((Session, TerminalView) -> Void)?
    /// Every new terminal, first pane or split, so the window can attach its handlers.
    var onTerminalCreated: ((TerminalView) -> Void)?

    init(runtime: TerminalRuntime) {
        self.runtime = runtime
    }

    var selected: Session? { sessions.first { $0.id == selectedID } }

    @discardableResult
    func create(directory: String = NSHomeDirectory()) -> Session {
        create(PaneContainer(TerminalView(runtime: runtime, workingDirectory: directory)), directory: directory)
    }

    private func create(_ panes: PaneContainer, directory: String) -> Session {
        let session = Session(panes: panes, directory: directory)
        panes.terminals.forEach { wire($0, to: session) }
        panes.onFocusChange = { [weak self, weak session] in
            session?.show($0)
            self?.save()
        }
        panes.onLayoutChange = { [weak self] in self?.save() }

        sessions.append(session)
        onSessionCreated?(session)
        select(session)
        return session
    }

    /// Splits the focused pane. The new one opens in the same folder.
    func split(_ session: Session, _ direction: TerminalRequest.Direction) {
        let terminal = TerminalView(runtime: runtime, workingDirectory: session.panes.focused.workingDirectory)
        wire(terminal, to: session)
        session.panes.split(direction, with: terminal)
    }

    /// Every terminal reports to its session, but only the focused pane decides what the session shows.
    private func wire(_ terminal: TerminalView, to session: Session) {
        onTerminalCreated?(terminal)
        terminal.onTitleChange = { [weak session, weak terminal] in
            guard let session, terminal === session.panes.focused else { return }
            session.title = $0
            session.refreshGit()
        }
        terminal.onWorkingDirectoryChange = { [weak self, weak session, weak terminal] in
            guard let session, terminal === session.panes.focused else { return }
            session.directory = $0
            session.refreshGit()
            self?.save()
        }
        terminal.onBell = { [weak self, weak session] in self?.flag(session) }
        terminal.onNotification = { [weak self, weak session] _, _ in self?.flag(session) }
        terminal.onClose = { [weak self, weak session, weak terminal] in
            if let session, let terminal { self?.onPaneExit?(session, terminal) }
        }
    }

    // MARK: Restore

    private static let savedLayouts = "sessions.layouts"
    /// The format before split panes: one folder per session.
    private static let savedDirectories = "sessions.directories"
    private static let savedSelection = "sessions.selected"

    /// Reopens the sessions and panes from the last run. Missing folders fall back to home, and empty sessions are skipped.
    func restore() {
        let defaults = UserDefaults.standard
        // Read before creating sessions, since each one saves over it.
        let selected = defaults.integer(forKey: Self.savedSelection)
        let layouts = defaults.data(forKey: Self.savedLayouts)
            .flatMap { try? JSONDecoder().decode([PaneLayout].self, from: $0) }
            ?? (defaults.stringArray(forKey: Self.savedDirectories) ?? []).map { .terminal(directory: $0) }
        let exists = { FileManager.default.fileExists(atPath: $0) }
        let usable = layouts.filter { $0.directories.contains(where: exists) }
        guard !usable.isEmpty else {
            create()
            return
        }
        for layout in usable {
            let panes = PaneContainer(layout) { [runtime] directory in
                TerminalView(runtime: runtime, workingDirectory: exists(directory) ? directory : NSHomeDirectory())
            }
            create(panes, directory: panes.focused.workingDirectory ?? NSHomeDirectory())
        }
        select(index: min(selected, sessions.count - 1))
    }

    /// Saved on every change rather than at quit, so a crash keeps the sessions too.
    private func save() {
        let defaults = UserDefaults.standard
        let layouts = sessions.map(\.panes.layoutSnapshot)
        defaults.set(try? JSONEncoder().encode(layouts), forKey: Self.savedLayouts)
        defaults.removeObject(forKey: Self.savedDirectories)
        defaults.set(sessions.firstIndex { $0.id == selectedID } ?? 0, forKey: Self.savedSelection)
    }

    func select(_ session: Session) {
        session.status = .running
        selectedID = session.id
        onSelectionChange?(session)
        save()
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
            // Nothing to restore: the next launch starts fresh in the home folder.
            sessions.removeAll()
            save()
            onLastSessionClosed?()
            return
        }
        session.panes.removeFromSuperview()
        sessions.remove(at: index)
        if session.id == selectedID {
            select(sessions[min(index, sessions.count - 1)])
        } else {
            save()
        }
    }

    private func flag(_ session: Session?) {
        guard let session, session.id != selectedID else { return }
        session.status = .needsAttention
    }
}
