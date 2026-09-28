import AppKit
import Combine
import SwiftUI
import GhosttyTerminal

/// Top bar, session sidebar, and the selected terminal or the settings page.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    /// Same height as the native title bar, so the buttons line up with the traffic lights.
    private static let topBarHeight: CGFloat = 28

    let store: SessionStore
    private let runtime: TerminalRuntime
    private let state: WindowState

    private lazy var notifier = AgentNotifier(settings: agents)
    private let content = NSView()
    private let terminalContainer = NSView()
    private var sidebarWidth: NSLayoutConstraint!
    private var filesWidth: NSLayoutConstraint!
    private let files = FileTree()
    /// Follows the selected session's folder while the files panel is open.
    private var filesRoot: AnyCancellable?
    private static let filesVisibleKey = "files.visible"
    private var settingsView: NSView!

    let agents: AgentSettings
    private let updates = UpdateChecker()
    private var badgeSwitch: AnyCancellable?

    init(store: SessionStore, runtime: TerminalRuntime, settings: Settings, agents: AgentSettings) {
        self.agents = agents
        self.store = store
        self.runtime = runtime
        let base = runtime.ghosttyConfigColors
        self.state = WindowState(
            palette: Palette(runtime),
            ghosttyConfigPreview: ThemeColors(background: base.background, foreground: base.foreground))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 640, height: 360)

        super.init(window: window)
        window.delegate = self

        let commands = Commands(
            newSession: { [weak self] in self?.newSession() },
            newTask: { [weak self] in self?.newTask() },
            closeSession: { [weak self] in self?.requestClose($0) },
            toggleSidebar: { [weak self] in self?.toggleSidebar() },
            toggleFiles: { [weak self] in self?.toggleFiles() },
            toggleSettings: { [weak self] in self?.toggleSettings() },
            titleBarDoubleClick: { [weak self] in self?.titleBarDoubleClicked() })

        let root = NSView()
        let topBar = hosting(TopBar(state: state, store: store, updates: updates, commands: commands))
        let sidebar = hosting(SidebarView(store: store, state: state, commands: commands))
        sidebar.clipsToBounds = true
        let filesPanel = hosting(FilesPanel(tree: files, state: state) { [weak self] path in
            self?.store.selected?.panes.open(path)
        })
        filesPanel.clipsToBounds = true
        state.filesVisible = UserDefaults.standard.bool(forKey: Self.filesVisibleKey)
        settingsView = hosting(SettingsPage(settings: settings, agents: agents, state: state, updates: updates))
        settingsView.isHidden = true

        content.wantsLayer = true
        for v in [topBar, sidebar, filesPanel, content] { root.addSubview(v) }
        for v in [terminalContainer, settingsView!] { content.addSubview(v) }
        for v in [topBar, sidebar, filesPanel, content, terminalContainer, settingsView!] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: SidebarView.width)
        filesWidth = filesPanel.widthAnchor.constraint(equalToConstant: state.filesVisible ? FilesPanel.width : 0)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: Self.topBarHeight),

            sidebar.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth,

            filesPanel.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            filesPanel.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            filesPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            filesWidth,

            content.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: filesPanel.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // Breathing room around the text. It shares the terminal background, so it reads as terminal.
            terminalContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            terminalContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            terminalContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            terminalContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),

            settingsView.topAnchor.constraint(equalTo: content.topAnchor),
            settingsView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            settingsView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            settingsView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        window.contentView = root
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.setFrameAutosaveName("FarolMain")
        if !window.setFrameUsingName("FarolMain") { window.center() }

        applyTheme()
        runtime.onConfigChange = { [weak self] in self?.applyTheme() }
        store.onSessionCreated = { [weak self] in self?.host($0) }
        store.onTerminalCreated = { [weak self] in self?.configure($0) }
        store.onPaneExit = { [weak self] in self?.paneExited($1, in: $0) }
        runtime.onRequest = { [weak self] in self?.handle($0) }
        store.onActivityChange = { [weak self] session, before, after in
            guard let self else { return }
            notifier.activityChanged(session, from: before, to: after)
            refreshBadge(enabled: agents.dockBadge)
        }
        // @Published reports the new value before the property changes, so pass it along.
        badgeSwitch = agents.$dockBadge.dropFirst().sink { [weak self] in self?.refreshBadge(enabled: $0) }
        notifier.onOpen = { [weak self] id in
            guard let self, let session = self.store.sessions.first(where: { $0.id == id }) else { return }
            self.store.select(session)
        }
        store.onSelectionChange = { [weak self] in
            self?.state.showingSettings = false
            self?.show($0)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Commands

    /// Key bindings from Ghostty's defaults or the user's config that need the app.
    func handle(_ request: TerminalRequest) {
        switch request {
        case .newSession: newSession()
        case .closeSession: store.selected.map(requestClose)
        case .closeWindow, .quit: NSApp.terminate(nil)
        case .gotoSession(let index): store.select(index: index)
        case .previousSession: store.selectNext(offset: -1)
        case .nextSession: store.selectNext(offset: 1)
        case .lastSession: store.select(index: store.sessions.count - 1)
        case .toggleFullscreen: window?.toggleFullScreen(nil)
        case .reloadConfig: runtime.reloadConfig()
        case .openSettings: if !state.showingSettings { toggleSettings() }
        case .newSplit(let direction): store.selected.map { store.split($0, direction) }
        case .gotoSplit(let target): store.selected?.panes.goto(target)
        case .resizeSplit(let direction, let amount): store.selected?.panes.resize(direction, by: amount)
        case .equalizeSplits: store.selected?.panes.equalize()
        case .toggleSplitZoom:
            store.selected?.panes.toggleZoom()
            store.selected?.panes.setVisible(true)
        }
    }

    /// Farol is one window, so closing it quits, which asks first when programs are running.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    /// Asks before quitting kills running programs.
    func confirmQuit(_ reply: @escaping (Bool) -> Void) {
        // Unsaved files first, one at a time, each shown in its session.
        if let session = store.sessions.first(where: { $0.panes.file?.isDirty == true }), let file = session.panes.file {
            store.select(session)
            return file.confirmClose({ [weak self] in self?.confirmQuit(reply) }, cancelled: { reply(false) })
        }
        guard runtime.hasRunningProcesses, let window else { return reply(true) }
        let alert = NSAlert()
        alert.messageText = "Quit Farol?"
        alert.informativeText = "Programs are still running. Quitting stops them."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { reply($0 == .alertFirstButtonReturn) }
    }

    /// Opens where you are: the focused pane's folder, or home when there is no session yet.
    func newSession() {
        store.create(directory: store.selected?.panes.focused.workingDirectory ?? NSHomeDirectory(), run: agents.startCommand)
    }

    func toggleSidebar() {
        let open = sidebarWidth.constant == 0
        withAnimation(.easeOut(duration: 0.18)) { state.sidebarVisible = open }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            sidebarWidth.animator().constant = open ? SidebarView.width : 0
        }
    }

    /// Opens or closes the files panel. It remembers the choice, and only watches the disk while open.
    func toggleFiles() {
        let open = !state.filesVisible
        UserDefaults.standard.set(open, forKey: Self.filesVisibleKey)
        withAnimation(.easeOut(duration: 0.18)) { state.filesVisible = open }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            filesWidth.animator().constant = open ? FilesPanel.width : 0
        }
        followFiles(store.selected)
    }

    private func followFiles(_ session: Session?) {
        guard state.filesVisible, let session else {
            filesRoot = nil
            files.show(nil)
            return
        }
        filesRoot = session.$topLevel.combineLatest(session.$directory)
            .sink { [weak self] topLevel, directory in self?.files.show(topLevel ?? directory) }
    }

    /// Does what the user chose in System Settings for a title bar double-click: zoom, minimize or nothing.
    func titleBarDoubleClicked() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window?.performMiniaturize(nil)
        case "None": break
        default: window?.performZoom(nil)
        }
    }

    func toggleSettings() {
        state.showingSettings.toggle()
        show(store.selected)
    }

    // MARK: Layout

    private func hosting<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        // The constraints own the size, so SwiftUI's ideal size must not fight them.
        host.sizingOptions = []
        // The window draws under its title bar, and SwiftUI would otherwise pad for it.
        host.safeAreaRegions = []
        return host
    }

    private func applyTheme() {
        let bg = runtime.backgroundColor
        state.palette = Palette(runtime)
        window?.backgroundColor = bg
        window?.appearance = NSAppearance(named: bg.isDark ? .darkAqua : .aqua)
        content.layer?.backgroundColor = bg.cgColor
        store.sessions.forEach { $0.panes.theme = theme }
    }

    private var theme: (background: NSColor, foreground: NSColor) { (runtime.backgroundColor, runtime.foregroundColor) }

    private func refreshBadge(enabled: Bool) {
        notifier.updateBadge(waiting: enabled ? store.sessions.filter { $0.activity == .waiting }.count : 0)
    }

    // MARK: Find

    func namePane() { store.selected?.panes.nameFocusedPane() }
    /// The open file when it has focus, else the terminal search.
    private var focusedFile: FileView? {
        guard let panes = store.selected?.panes, panes.fileFocused else { return nil }
        return panes.file
    }

    var canSaveFile: Bool { focusedFile != nil }

    func saveFile() {
        guard let file = focusedFile, let window else { return }
        do {
            try file.save()
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    func find() {
        if let file = focusedFile { return file.find(.showFindInterface) }
        store.selected?.panes.focused.startSearch()
    }
    func findNext() {
        if let file = focusedFile { return file.find(.nextMatch) }
        store.selected?.panes.searchTarget.searchNext()
    }
    func findPrevious() {
        if let file = focusedFile { return file.find(.previousMatch) }
        store.selected?.panes.searchTarget.searchPrevious()
    }
    func findSelection() {
        if let file = focusedFile { return file.find(.setSearchString) }
        store.selected?.panes.focused.searchSelection()
    }

    private func host(_ session: Session) {
        session.panes.frame = terminalContainer.bounds
        session.panes.autoresizingMask = [.width, .height]
        session.panes.theme = theme
        terminalContainer.addSubview(session.panes)
    }

    private func configure(_ terminal: TerminalView) {
        terminal.onClipboardRequest = { [weak self] request, reply in self?.confirm(request, reply: reply) }
        terminal.onRequest = { [weak self] in self?.handle($0) }
    }

    private func confirm(_ request: ClipboardRequest, reply: @escaping (Bool) -> Void) {
        guard let window else { return reply(false) }
        let alert = NSAlert()
        let preview = request.text.count > 400 ? request.text.prefix(400) + "…" : Substring(request.text)
        switch request.kind {
        case .paste:
            let lines = request.text.split(separator: "\n", omittingEmptySubsequences: false).count
            alert.messageText = "Paste \(lines) lines?"
            alert.informativeText = "Text with line breaks can run commands as soon as it is pasted.\n\n\(preview)"
            alert.addButton(withTitle: "Paste")
        case .programRead:
            alert.messageText = "Let this program read your clipboard?"
            alert.informativeText = "A program in this session asked for what you last copied."
            alert.addButton(withTitle: "Allow")
        case .programWrite:
            alert.messageText = "Let this program set your clipboard?"
            alert.informativeText = String(preview)
            alert.addButton(withTitle: "Allow")
        }
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { reply($0 == .alertFirstButtonReturn) }
    }

    /// Only the terminal on screen renders. Settings replaces it and pauses it too.
    private func show(_ session: Session?) {
        let settings = state.showingSettings
        settingsView.isHidden = !settings
        terminalContainer.isHidden = settings
        for s in store.sessions {
            s.panes.setVisible(!settings && s.id == session?.id)
        }
        if !settings, let session { window?.makeFirstResponder(session.panes.focusTarget) }
        followFiles(session)
    }
}
