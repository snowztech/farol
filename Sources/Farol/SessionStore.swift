import AppKit
import FarolCore
import GhosttyTerminal

final class Session: ObservableObject, Identifiable {
    /// What the sidebar lamp shows. Stopped is git, not the agent: a merge or rebase waiting on you, which outranks the rest.
    enum Activity { case idle, working, waiting, done, stopped }

    let id = UUID()
    let panes: PaneContainer
    @Published var title = ""
    /// Set by renaming the session in the sidebar. Wins over every automatic name.
    @Published var customName: String?
    @Published var directory: String
    /// Reported per pane by agent hooks or interactive terminal titles.
    @Published private(set) var agents: [UUID: AgentActivity] = [:]
    /// The program rang the bell or sent a notification while you were elsewhere. Covers agents without hooks.
    @Published var bellRang = false
    /// The host each pane is on over ssh, kept apart from the title so it outlives a program retitling the pane.
    @Published private var remotes: [UUID: RemoteTitle] = [:]
    @Published private(set) var branch: String?
    @Published private(set) var repoName: String?
    /// The main checkout's path, the same for every worktree of a repo. Sessions are grouped by it.
    @Published private(set) var repoRoot: String?
    /// The top of the checkout the session is in, a worktree's own folder for worktrees. The files panel starts there.
    @Published private(set) var topLevel: String?
    /// A merge, rebase, cherry-pick or revert git stopped on in this checkout, often one an agent started.
    @Published private(set) var stopped: Merge.Operation?
    /// Files still in conflict while stopped.
    @Published private(set) var conflicts = 0
    /// Lets the store regroup the sidebar when a session turns out to be in another repo.
    var onRepoChange: (() -> Void)?
    /// Git stopping or going on changes the activity, which the store reports like an agent's. Gets the activity before.
    var onGitStateChange: ((Activity) -> Void)?
    /// Set when the session runs in one of Farol's worktrees, even after `cd` into a subfolder.
    let worktree: String?
    private var refreshingGit = false
    private var refreshGitAgain = false

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

    /// The most urgent state across the session's panes. Closed panes no longer count.
    var activity: Activity {
        let live = Set(panes.terminals.map(\.id))
        let statuses = agents.filter { live.contains($0.key) }.values.compactMap(\.status)
        if stopped != nil { return .stopped }
        if bellRang || statuses.contains(.waiting) { return .waiting }
        if statuses.contains(.working) { return .working }
        if statuses.contains(.done) { return .done }
        return .idle
    }

    func apply(_ event: AgentEvent, pane: UUID) {
        agents[pane, default: AgentActivity()].apply(event)
    }

    /// An agent in one of the panes waits for your approval or answer, as opposed to a bell or terminal notification.
    var agentIsWaiting: Bool { agents.values.contains { $0.status == .waiting } }

    /// Looking at the session is the acknowledgement, so the bell and "done" clear.
    func acknowledge() {
        bellRang = false
        for pane in agents.keys { agents[pane]?.acknowledge() }
    }

    /// Looks up the branch off the main thread. The shell reports its folder at every prompt, so a `git checkout` shows up too.
    func refreshGit() {
        // One lookup at a time: prompts can come faster than git answers, and answers must land in order.
        guard !refreshingGit else { return refreshGitAgain = true }
        refreshingGit = true
        let directory = directory
        DispatchQueue.global(qos: .userInitiated).async {
            let branch = Git.branch(of: directory)
            let root = Git.repoRoot(of: directory)
            let topLevel = Git.topLevel(of: directory)
            let operation = topLevel.flatMap { Merge.operation(in: $0) }
            let conflicts = topLevel.flatMap { top in operation.map { Merge.conflicts(in: top, $0.kind).count } } ?? 0
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshingGit = false
                if self.refreshGitAgain {
                    self.refreshGitAgain = false
                    self.refreshGit()
                }
                guard self.directory == directory else { return }
                let before = self.activity
                if self.stopped != operation { self.stopped = operation }
                if self.conflicts != conflicts { self.conflicts = conflicts }
                if self.activity != before { self.onGitStateChange?(before) }
                self.branch = branch
                if self.topLevel != topLevel { self.topLevel = topLevel }
                self.repoName = root.map { URL(fileURLWithPath: $0).lastPathComponent }
                if self.repoRoot != root {
                    self.repoRoot = root
                    self.onRepoChange?()
                }
            }
        }
    }

    /// Shells default to titles like "user@host:~/dir", which read worse than the folder name, unless the host is remote.
    /// Programs that set a real title (Claude Code, vim, htop) keep it.
    /// A worktree folder is named after its branch, so the repo name says more there.
    var displayName: String {
        if let customName { return customName }
        if let remote { return remote.host }
        if hasProgramTitle { return programTitle }
        if worktree != nil, let repoName { return repoName }
        return folderName
    }

    /// The second line when there is no branch, so every row has the same height.
    var location: String? {
        guard branch == nil else { return nil }
        return (directory as NSString).abbreviatingWithTildeInPath
    }

    /// The second line over ssh, where the local branch says nothing about the machine you are on.
    var remoteLocation: String? { remote?.path }

    private var remote: RemoteTitle? { remotes[panes.focused.id] }

    func noteTitle(_ title: String, pane: UUID) {
        let remote = RemoteTitle.after(title, was: remotes[pane])
        if remotes[pane] != remote { remotes[pane] = remote }
    }

    /// Agents put their status in the title, like Claude Code's ✳. The sidebar dot already shows it.
    private var programTitle: String { AgentTitle.withoutStatus(title) }

    /// Shells title the window with the folder, sometimes shortened to "…/dev/project" or "dev/project".
    /// A path has a slash and no spaces, while a program title like "vim src/main.swift" has spaces.
    /// Until a program sets a title, Ghostty uses the full folder path, which can have spaces.
    private var hasProgramTitle: Bool {
        let looksLikePath = title.hasPrefix("/") || title.contains("/") && !title.contains(" ")
        return !(title.isEmpty || title.contains("@") || title.hasPrefix("~") || looksLikePath)
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

    /// A session's activity changed, from the old value to the new one. Used for notifications.
    var onActivityChange: ((Session, Session.Activity, Session.Activity) -> Void)?

    private let statusServer: StatusServer
    private let cliPath: String

    /// `socketPath` is where `farol status` reports. Each app build gets its own, so dev builds never mix with yours.
    init(runtime: TerminalRuntime, socketPath: String) {
        self.runtime = runtime
        cliPath = Bundle.main.resourceURL?.appendingPathComponent("bin/farol").path ?? "farol"
        statusServer = StatusServer(path: socketPath)
        statusServer.onMessage = { [weak self] in self?.receive($0) }
        do {
            try statusServer.start()
        } catch {
            NSLog("Farol: agent status is off, the socket failed to start: \(error)")
        }
    }

    /// Every terminal gets its id and the socket in its environment, so its shell can report back.
    private func makeTerminal(in directory: String?, run: String? = nil) -> TerminalView {
        let id = UUID()
        let command = run?.trimmingCharacters(in: .whitespaces) ?? ""
        return TerminalView(runtime: runtime, workingDirectory: directory, id: id, environment: [
            "FAROL_PANE": id.uuidString,
            "FAROL_SOCKET": statusServer.path,
            "FAROL_CLI": cliPath,
        ], input: command.isEmpty ? nil : command + "\n")
    }

    private func receive(_ message: StatusMessage) {
        guard let pane = UUID(uuidString: message.pane),
              let session = sessions.first(where: { $0.panes.terminals.contains { $0.id == pane } }) else { return }
        let before = session.activity
        session.apply(message.event, pane: pane)
        // An agent's turn can end on a rebase it started and git stopped, so its checkout is looked at again.
        session.refreshGit()
        // A "done" you are already looking at needs no light.
        if session.id == selectedID && NSApp.isActive { session.acknowledge() }
        report(session, from: before)
    }

    private func report(_ session: Session, from before: Session.Activity) {
        let after = session.activity
        if after != before { onActivityChange?(session, before, after) }
    }

    var selected: Session? { sessions.first { $0.id == selectedID } }

    /// Settings → Appearance → Group sessions by project. Off unless turned on.
    static let groupByRepoKey = "sidebar.groupByRepo"

    /// The sidebar's sections: one per repo once sessions span several, else a single unnamed one.
    var groups: [Grouping.Group<Session>] {
        guard UserDefaults.standard.bool(forKey: Self.groupByRepoKey) else {
            return [Grouping.Group(key: nil, items: sessions)]
        }
        return Grouping.group(sessions, by: \.repoRoot)
    }

    /// Sessions in the order the sidebar shows them, which ⌘1 to ⌘9 and next or previous follow.
    var ordered: [Session] { groups.flatMap(\.items) }

    /// `run` is typed into the new shell, for example "claude" to start an agent right away.
    @discardableResult
    func create(directory: String = NSHomeDirectory(), run: String? = nil) -> Session {
        create(PaneContainer(makeTerminal(in: directory, run: run)), directory: directory)
    }

    /// An empty name goes back to the automatic one.
    func rename(_ session: Session, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        session.customName = trimmed.isEmpty ? nil : trimmed
        save()
    }

    /// Moves a session to another place in the sidebar. ⌘1 to ⌘9 follow the new order.
    func move(_ session: Session, to index: Int) {
        guard let from = sessions.firstIndex(where: { $0 === session }), from != index,
              sessions.indices.contains(index) else { return }
        sessions.move(fromOffsets: IndexSet(integer: from), toOffset: index > from ? index + 1 : index)
        save()
    }

    private func create(_ panes: PaneContainer, directory: String) -> Session {
        let session = Session(panes: panes, directory: directory)
        panes.terminals.forEach { wire($0, to: session) }
        panes.onFocusChange = { [weak self, weak session] in
            session?.show($0)
            self?.save()
        }
        panes.onLayoutChange = { [weak self] in self?.save() }
        session.onRepoChange = { [weak self] in self?.objectWillChange.send() }
        session.onGitStateChange = { [weak self, weak session] before in
            guard let self, let session else { return }
            self.report(session, from: before)
        }

        sessions.append(session)
        onSessionCreated?(session)
        select(session)
        return session
    }

    /// Splits the focused pane. The new one opens in the same folder, and runs `run` when given.
    func split(_ session: Session, _ direction: TerminalRequest.Direction, run: String? = nil) {
        let terminal = makeTerminal(in: session.panes.focused.workingDirectory, run: run)
        wire(terminal, to: session)
        session.panes.split(direction, with: terminal)
    }

    /// Every terminal reports to its session, but only the focused pane decides what the session shows.
    private func wire(_ terminal: TerminalView, to session: Session) {
        onTerminalCreated?(terminal)
        var previousTitle = terminal.title
        terminal.onTitleChange = { [weak self, weak session, weak terminal] in
            guard let self, let session, let terminal else { return }
            if let event = AgentTitle.event(from: previousTitle, to: $0) {
                receive(StatusMessage(pane: terminal.id.uuidString, event: event))
            }
            previousTitle = $0
            session.noteTitle($0, pane: terminal.id)
            guard terminal === session.panes.focused else { return }
            // Agents animate a glyph in the title many times a second, and those frames are not worth a git lookup.
            // The title is cleared when a command ends, which is one way a `git checkout` gets noticed.
            let glyphOnly = $0 != AgentTitle.withoutStatus($0) && AgentTitle.withoutStatus($0) == AgentTitle.withoutStatus(session.title)
            session.title = $0
            if !glyphOnly { session.refreshGit() }
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

    private static let savedSessions = "sessions.saved"
    /// Earlier formats: pane layouts without names, and before that one folder per session.
    private static let savedLayouts = "sessions.layouts"
    /// The format before split panes: one folder per session.
    private static let savedDirectories = "sessions.directories"
    private static let savedSelection = "sessions.selected"

    /// Reopens the sessions and panes from the last run. Missing folders fall back to home, and empty sessions are skipped.
    func restore() {
        let defaults = UserDefaults.standard
        // Read before creating sessions, since each one saves over it.
        let selected = defaults.integer(forKey: Self.savedSelection)
        let decoder = JSONDecoder()
        let saved = defaults.data(forKey: Self.savedSessions).flatMap { try? decoder.decode([SavedSession].self, from: $0) }
            ?? defaults.data(forKey: Self.savedLayouts)
                .flatMap { try? decoder.decode([PaneLayout].self, from: $0) }?.map { SavedSession(layout: $0) }
            ?? (defaults.stringArray(forKey: Self.savedDirectories) ?? []).map { SavedSession(layout: .terminal(directory: $0)) }
        let exists = { FileManager.default.fileExists(atPath: $0) }
        let usable = saved.filter { $0.layout.directories.contains(where: exists) }
        guard !usable.isEmpty else {
            create()
            return
        }
        for entry in usable {
            let panes = PaneContainer(entry.layout) { directory in
                self.makeTerminal(in: exists(directory) ? directory : NSHomeDirectory())
            }
            create(panes, directory: panes.focused.workingDirectory ?? NSHomeDirectory()).customName = entry.name
        }
        select(index: min(selected, sessions.count - 1))
    }

    /// Saved on every change rather than at quit, so a crash keeps the sessions too.
    private func save() {
        let defaults = UserDefaults.standard
        let saved = sessions.map { SavedSession(layout: $0.panes.layoutSnapshot, name: $0.customName) }
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.savedSessions)
        defaults.removeObject(forKey: Self.savedLayouts)
        defaults.removeObject(forKey: Self.savedDirectories)
        defaults.set(sessions.firstIndex { $0.id == selectedID } ?? 0, forKey: Self.savedSelection)
    }

    func select(_ session: Session) {
        let before = session.activity
        session.acknowledge()
        report(session, from: before)
        selectedID = session.id
        onSelectionChange?(session)
        save()
    }

    func select(index: Int) {
        let ordered = ordered
        guard ordered.indices.contains(index) else { return }
        select(ordered[index])
    }

    func selectNext(offset: Int) {
        let ordered = ordered
        guard let current = ordered.firstIndex(where: { $0.id == selectedID }), !ordered.isEmpty else { return }
        select(ordered[(current + offset + ordered.count) % ordered.count])
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
        // Where it sat on screen, so the session that takes its place is the one shown next to it.
        let shown = ordered.firstIndex { $0.id == session.id } ?? 0
        session.panes.removeFromSuperview()
        sessions.remove(at: index)
        if session.id == selectedID {
            let ordered = ordered
            select(ordered[min(shown, ordered.count - 1)])
        } else {
            save()
        }
    }

    private func flag(_ session: Session?) {
        guard let session, session.id != selectedID else { return }
        let before = session.activity
        session.bellRang = true
        report(session, from: before)
    }
}

/// What a session keeps between launches.
private struct SavedSession: Codable {
    var layout: PaneLayout
    var name: String?
}
