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
    /// The agent's own conversation, as its hooks last named it. A phone reads it.
    var conversation: AgentConversation?
    /// Each pane's conversation while its agent runs, saved so the next launch resumes it there.
    var conversations: [UUID: AgentConversation] = [:]
    /// What a waiting agent asks, and the pane it waits in, so an answer from a phone goes there and nowhere else.
    var request: (pane: UUID, asked: AgentRequest)?
    /// An agent started here and has not ended. Before its first message it may have no log, and a phone shows it as an empty conversation.
    var agentStarted = false
    /// The program rang the bell or sent a notification while you were elsewhere. Covers agents that report nothing themselves.
    @Published var bellRang = false
    /// The host each pane is on over ssh, kept apart from the title so it outlives a program retitling the pane.
    @Published private var remotes: [UUID: RemoteTitle] = [:]
    /// The focused pane is on another machine, where the local folder and its git state don't apply.
    @Published private(set) var isRemote = false
    @Published private(set) var branch: String?
    @Published private(set) var repoName: String?
    /// The main checkout's path, the same for every worktree of a repo. Sessions are grouped by it.
    @Published private(set) var repoRoot: String?
    /// The top of the checkout the session is in, a worktree's own folder for worktrees. The files panel starts there.
    @Published private(set) var topLevel: String?
    /// The checkout the git panels and the branch follow: the one you are in, or in a task the repo you picked.
    @Published private(set) var checkout: String?
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
    /// Set when the session runs in a task folder holding a worktree of several repos.
    let taskFolder: String?
    /// The worktrees in the task folder, in order.
    private let taskFolderRepos: [String]
    /// The task's repos while the session is in its folder. Empty once it `cd`s out, where it is a plain session again.
    @Published private(set) var taskRepos: [String] = []
    /// The task repo the git panels show. Until you pick one or `cd` into one, the first with changes, or else the first.
    private var pickedRepo: String?
    private var refreshingGit = false
    private var refreshGitAgain = false

    init(panes: PaneContainer, directory: String) {
        self.panes = panes
        self.directory = directory
        worktree = Worktrees.default.root(of: directory)
        taskFolder = TaskFolders.default.root(of: directory)
        taskFolderRepos = taskFolder.map(TaskFolders.repos(in:)) ?? []
        refreshGit()
    }

    /// The name, folder and branch follow whichever pane has focus.
    func show(_ terminal: TerminalView) {
        title = terminal.title
        syncRemote()
        if let folder = terminal.workingDirectory { directory = folder }
        refreshGit()
    }

    /// Shows another of the task's repos in the git panels.
    func pick(_ repo: String) {
        pickedRepo = repo
        refreshGit()
    }

    /// A repo with changes, to show first. Ignored once you have picked or gone into one.
    func suggest(_ repo: String) {
        guard pickedRepo == nil else { return }
        pick(repo)
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

    func apply(_ event: AgentEvent, pane: UUID, request: AgentRequest? = nil) {
        agents[pane, default: AgentActivity()].apply(event)
        switch event {
        // A notification that the agent still waits says nothing new, so what it asks is kept.
        case .waiting: if let request { self.request = (pane, request) }
        case .working, .done, .clear, .start: if self.request?.pane == pane { self.request = nil }
        case .subagentStart, .subagentStop: break
        }
        if event == .start { agentStarted = true }
        if event == .clear { agentStarted = false }
    }

    /// Claude Code runs no hook when you stop it, so a stop at the end of its log ends what its pane showed. True when one did.
    func noticeStop() -> Bool {
        guard let log = conversation?.log else { return false }
        var stopped = false
        for (pane, agent) in agents where agent.status == .working || agent.status == .waiting {
            guard let since = agent.since, Transcript.stopped(log: log, since: since) else { continue }
            agents[pane]?.stop()
            if request?.pane == pane { request = nil }
            stopped = true
        }
        return stopped
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
        let taskFolder = taskFolder, before = topLevel, picked = pickedRepo ?? taskFolderRepos.first
        let allTaskRepos = taskFolderRepos
        DispatchQueue.global(qos: .userInitiated).async {
            let root = Git.repoRoot(of: directory)
            let topLevel = Git.topLevel(of: directory)
            let inTask = taskFolder != nil && TaskFolders.default.root(of: directory) == taskFolder
            let taskRepos = inTask ? allTaskRepos : []
            // In a task the panels follow the last repo you went into or clicked, so a click wins until the next `cd`.
            let moved = topLevel != before && topLevel.map(taskRepos.contains) == true
            let checkout = taskRepos.isEmpty ? topLevel : moved ? topLevel : picked
            let branch = Git.branch(of: checkout ?? directory)
            let operation = checkout.flatMap { Merge.operation(in: $0) }
            let conflicts = checkout.flatMap { top in operation.map { Merge.conflicts(in: top, $0.kind).count } } ?? 0
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
                // Before the checkout, so whatever follows the checkout already sees which task it is in.
                if self.taskRepos != taskRepos { self.taskRepos = taskRepos }
                if self.checkout != checkout { self.checkout = checkout }
                // Only a `cd` moves the pick here, so a click made while git was answering isn't undone.
                if moved { self.pickedRepo = topLevel }
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
        if let remote, !hasProgramTitle { return remote.host }
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
    /// A program's title takes the name, so the host moves down here.
    var remoteLocation: String? { remote.map { hasProgramTitle ? $0.host : $0.path } }

    private var remote: RemoteTitle? { remotes[panes.focused.id] }

    func noteTitle(_ title: String, pane: UUID) {
        let remote = RemoteTitle.after(title, was: remotes[pane])
        if remotes[pane] != remote { remotes[pane] = remote }
        syncRemote()
    }

    private func syncRemote() {
        if isRemote != (remote != nil) { isRemote = remote != nil }
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
    private var stops: Timer?

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
        // Reads the end of the log of each agent that works or waits, a few kilobytes, and nothing while none does.
        stops = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            for session in sessions {
                let before = session.activity
                if session.noticeStop() { report(session, from: before) }
            }
        }
    }

    /// Every terminal gets its id and the socket in its environment, so its shell can report back.
    private func makeTerminal(in directory: String?, run: String? = nil, environment: [String: String] = [:]) -> TerminalView {
        let id = UUID()
        let command = run?.trimmingCharacters(in: .whitespaces) ?? ""
        return TerminalView(runtime: runtime, workingDirectory: directory ?? OpenPath.fallback, id: id, environment: [
            "FAROL_PANE": id.uuidString,
            "FAROL_SOCKET": statusServer.path,
            "FAROL_CLI": cliPath,
        ].merging(environment) { $1 }, input: command.isEmpty ? nil : command + "\n")
    }

    private func receive(_ message: StatusMessage) {
        guard let pane = UUID(uuidString: message.pane),
              let session = sessions.first(where: { $0.panes.terminals.contains { $0.id == pane } }) else { return }
        let before = session.activity
        let resumable = session.conversations[pane]
        if let conversation = message.conversation {
            session.conversation = conversation
            session.conversations[pane] = conversation
        }
        // The agent ended, so there is nothing to resume. Codex also sends this when you interrupt a turn, and its next prompt brings it back.
        if message.event == .clear { session.conversations[pane] = nil }
        if session.conversations[pane] != resumable { save() }
        session.apply(message.event, pane: pane, request: message.request)
        // An agent can end its turn, or stop to ask you, on a rebase git stopped, so every session's checkout is looked at again.
        // Not on "working": it comes after every tool call, and each lookup also refreshes the review panel.
        if message.event == .done || message.event == .waiting { session.refreshGit() }
        // A "done" you are already looking at needs no light.
        if session.id == selectedID && NSApp.isActive { session.acknowledge() }
        report(session, from: before)
    }

    /// Codex's interactive TUI runs no hooks, so once a turn ends its conversation is looked up in its logs, for the next launch to resume.
    private func findCodexConversation(of terminal: TerminalView, in session: Session) {
        guard let program = terminal.foregroundProgram, program.name == "codex", let folder = terminal.workingDirectory else { return }
        let accounts = AgentFolder.find()
        DispatchQueue.global(qos: .utility).async { [weak self, weak session, weak terminal] in
            let found = AgentFolder.lastCodexConversation(in: accounts, startedIn: folder, since: program.started)
            DispatchQueue.main.async {
                guard let self, let session, let terminal, let found, session.conversations[terminal.id] != found else { return }
                session.conversations[terminal.id] = found
                self.save()
            }
        }
    }

    /// An agent still running keeps its conversation for the next launch.
    /// A pane back at its shell prompt had its agent end, which Codex's interactive TUI never reports, and an agent killed outright couldn't.
    func prepareToQuit() {
        for session in sessions {
            for terminal in session.panes.terminals where !terminal.runsProgram { session.conversations[terminal.id] = nil }
        }
        save()
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
    /// `environment` holds what is too long to type, which `run` can name as a variable.
    @discardableResult
    func create(directory: String = NSHomeDirectory(), run: String? = nil, environment: [String: String] = [:]) -> Session {
        create(PaneContainer(makeTerminal(in: directory, run: run, environment: environment)), directory: directory)
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
                if event == .done || event == .waiting { findCodexConversation(of: terminal, in: session) }
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
        terminal.onBell = { [weak self, weak session, weak terminal] in self?.flag(session, pane: terminal?.id) }
        terminal.onNotification = { [weak self, weak session, weak terminal] _, _ in self?.flag(session, pane: terminal?.id) }
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
        let resume = defaults.bool(forKey: AgentSettings.resumeKey)
        for entry in usable {
            var resumed: [UUID: AgentConversation] = [:]
            let panes = PaneContainer(entry.layout) { directory, conversation in
                // Only in its own folder, where the agent finds the conversation, and only while its log is still there.
                guard resume, exists(directory), let conversation, exists(conversation.log),
                      let agent = AgentFolder(log: conversation.log) else {
                    return self.makeTerminal(in: exists(directory) ? directory : NSHomeDirectory())
                }
                let terminal = self.makeTerminal(in: directory, run: agent.resume(conversation.id))
                resumed[terminal.id] = conversation
                return terminal
            }
            let session = create(panes, directory: panes.focused.workingDirectory ?? NSHomeDirectory())
            session.customName = entry.name
            // Kept before the agent reports again, so quitting right away still resumes it next time.
            session.conversations = resumed
            session.conversation = resumed.values.first
        }
        select(index: min(selected, sessions.count - 1))
    }

    /// Saved on every change rather than at quit, so a crash keeps the sessions too.
    private func save() {
        let defaults = UserDefaults.standard
        let saved = sessions.map { SavedSession(layout: $0.panes.layoutSnapshot(conversations: $0.conversations), name: $0.customName) }
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
        session.panes.terminals.forEach { $0.close() }
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

    private func flag(_ session: Session?, pane: UUID?) {
        guard let session, session.id != selectedID, let pane, session.agents[pane]?.reports != true else { return }
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
