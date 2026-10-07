import AppKit
import UniformTypeIdentifiers
import FarolCore
import Combine
import SwiftUI
import GhosttyTerminal

/// Top bar, session sidebar, and the selected terminal or the settings page.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    /// Same height as the native title bar, so the buttons line up with the traffic lights.
    private static let topBarHeight: CGFloat = 28

    let store: SessionStore
    private let runtime: TerminalRuntime
    private let settings: Settings
    let state: WindowState

    private lazy var notifier = AgentNotifier(settings: agents)
    private let content = NSView()
    private let terminalContainer = NSView()
    private var sidebarWidth: NSLayoutConstraint!
    private var filesWidth: NSLayoutConstraint!
    private let files = FileTree()
    /// Follows the selected session's folder while the files panel is open.
    private var filesRoot: AnyCancellable?
    private static let filesVisibleKey = "files.visible"
    private var graphWidth: NSLayoutConstraint!
    private let graph = GraphModel()
    /// Follows the selected session's checkout and branch while the graph panel is open.
    private var graphFollow: AnyCancellable?
    private static let graphVisibleKey = "graph.visible"
    private static let graphWidthKey = "graph.width"
    private var reviewWidth: NSLayoutConstraint!
    private let review = ReviewModel()
    /// Follows the selected session's checkout and branch, so the count in the title bar stays current.
    private var reviewFollow: AnyCancellable?
    private static let reviewWidthKey = "review.width"
    private var settingsView: NSView!
    private let merge = MergeModel()
    private let mergeEditor = MergeEditorController()
    private var mergeView: NSView!
    /// Follows the selected session's checkout, so the title bar shows when git stops on conflicts.
    private var mergeFollow: AnyCancellable?
    private var mergeDone: AnyCancellable?
    private var mergeCount: AnyCancellable?

    let agents: AgentSettings
    let worktreeSettings: WorktreeSettings
    private let updates = UpdateChecker()
    private var badgeSwitch: AnyCancellable?
    private var styleSwitch: AnyCancellable?
    /// Every panel below the title bar, left to right. Boxed, each is a card of its own.
    private var panels: [NSView] = []
    /// The space before each panel, in the same order, then after the last one, then under each.
    private var gaps: (before: [NSLayoutConstraint], after: NSLayoutConstraint?, under: [NSLayoutConstraint]) = ([], nil, [])
    private lazy var menuBar = MenuBarStatus(store: store, palette: state.palette)
    private var menuBarSwitch: AnyCancellable?
    private lazy var notch = NotchStatus(store: store, palette: state.palette)
    private var notchSwitch: AnyCancellable?
    private var notchPlace: AnyCancellable?
    private var sessionsChange: AnyCancellable?

    init(store: SessionStore, runtime: TerminalRuntime, settings: Settings, agents: AgentSettings,
         worktrees: WorktreeSettings) {
        self.agents = agents
        self.worktreeSettings = worktrees
        self.store = store
        self.runtime = runtime
        self.settings = settings
        self.state = WindowState(
            palette: Palette(runtime, style: UIStyle.saved),
            ghosttyConfigPreview: runtime.ghosttyConfigColors.map { ThemeColors(background: $0.background, foreground: $0.foreground) })

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
            toggleGraph: { [weak self] in self?.toggleGraph() },
            toggleReview: { [weak self] in self?.toggleReview() },
            toggleSettings: { [weak self] in self?.toggleSettings() },
            toggleMerge: { [weak self] in self?.toggleMerge() },
            openFile: { [weak self] in self?.open($0) },
            newSessionIn: { [weak self] in self?.newSession(in: $0) },
            titleBarDoubleClick: { [weak self] in self?.titleBarDoubleClicked() })

        let root = NSView()
        let topBar = hosting(TopBar(state: state, store: store, updates: updates, review: review, merge: merge, commands: commands))
        let sidebar = hosting(SidebarView(store: store, state: state, commands: commands))
        sidebar.clipsToBounds = true
        let filesPanel = hosting(FilesPanel(tree: files, state: state) { [weak self] path in
            self?.open(path)
        })
        filesPanel.clipsToBounds = true
        let graphPanel = hosting(GraphPanel(graph: graph, state: state) { [weak self] in self?.setGraphWidth($0) })
        graphPanel.clipsToBounds = true
        let reviewPanel = hosting(ReviewPanel(
            review: review, state: state,
            open: { [weak self] in self?.open($0, line: $1) },
            close: { [weak self] in self?.toggleReview(closing: true) },
            resize: { [weak self] in self?.setReviewWidth($0) }))
        reviewPanel.clipsToBounds = true
        state.filesVisible = UserDefaults.standard.bool(forKey: Self.filesVisibleKey)
        state.graphVisible = UserDefaults.standard.bool(forKey: Self.graphVisibleKey)
        settingsView = hosting(SettingsPage(
            settings: settings, agents: agents, worktrees: worktrees, state: state, updates: updates,
            runInTerminal: { [weak self] command in
                guard let self else { return }
                if state.showingSettings { toggleSettings() }
                store.create(run: command)
            }))
        settingsView.isHidden = true
        settingsView.wantsLayer = true
        mergeView = hosting(MergePanel(
            merge: merge, controller: mergeEditor, state: state,
            close: { [weak self] in self?.toggleMerge() },
            runInPane: { [weak self] in self?.runAfterMerge($0) },
            askAgent: { [weak self] in self?.askAgent($0) }))
        mergeView.isHidden = true
        mergeView.wantsLayer = true
        mergeView.clipsToBounds = true

        content.wantsLayer = true
        for v in [topBar, sidebar, filesPanel, graphPanel, content, reviewPanel] { root.addSubview(v) }
        for v in [terminalContainer, settingsView!] { content.addSubview(v) }
        // Over the side panels too: three columns of code need the whole width.
        root.addSubview(mergeView)
        for v in [topBar, sidebar, filesPanel, graphPanel, content, reviewPanel, terminalContainer, settingsView!, mergeView!] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: SidebarView.width)
        filesWidth = filesPanel.widthAnchor.constraint(equalToConstant: state.filesVisible ? FilesPanel.width : 0)
        state.graphWidth = state.graphVisible ? savedGraphWidth : 0
        graphWidth = graphPanel.widthAnchor.constraint(equalToConstant: state.graphWidth)
        reviewWidth = reviewPanel.widthAnchor.constraint(equalToConstant: 0)
        panels = [sidebar, filesPanel, content, reviewPanel, graphPanel]
        var edge = root.leadingAnchor
        for panel in panels {
            panel.wantsLayer = true
            gaps.before.append(panel.leadingAnchor.constraint(equalTo: edge))
            gaps.under.append(root.bottomAnchor.constraint(equalTo: panel.bottomAnchor))
            edge = panel.trailingAnchor
        }
        gaps.after = root.trailingAnchor.constraint(equalTo: edge)
        NSLayoutConstraint.activate(gaps.before + gaps.under + [gaps.after!])
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: Self.topBarHeight),

            sidebar.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            sidebarWidth,

            filesPanel.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            filesWidth,

            graphPanel.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            graphWidth,

            content.topAnchor.constraint(equalTo: topBar.bottomAnchor),

            reviewPanel.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            reviewWidth,

            // Breathing room around the text. It shares the terminal background, so it reads as terminal.
            terminalContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            terminalContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            terminalContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            terminalContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),

            settingsView.topAnchor.constraint(equalTo: content.topAnchor),
            settingsView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            settingsView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            settingsView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            mergeView.topAnchor.constraint(equalTo: content.topAnchor),
            mergeView.leadingAnchor.constraint(equalTo: filesPanel.leadingAnchor),
            mergeView.trailingAnchor.constraint(equalTo: graphPanel.trailingAnchor),
            mergeView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        window.contentView = root
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.setFrameAutosaveName("FarolMain")
        if !window.setFrameUsingName("FarolMain") { window.center() }

        applyTheme()
        settings.configErrors = runtime.configErrors
        runtime.onConfigChange = { [weak self] in
            self?.applyTheme()
            self?.reportConfigErrors()
        }
        graph.onGitChange = { [weak self] in self?.store.selected?.refreshGit() }
        graph.onShowInReview = { [weak self] commit, file in
            guard let self else { return }
            review.show(commit: commit.hash, subject: commit.subject, file: file)
            if !review.isOpen { toggleReview() }
        }
        graph.onRunInTerminal = { command in
            guard let session = store.selected else { return }
            store.split(session, .down, run: command)
        }
        store.onSessionCreated = { [weak self] in self?.host($0) }
        store.onTerminalCreated = { [weak self] in self?.configure($0) }
        store.onPaneExit = { [weak self] in self?.paneExited($1, in: $0) }
        runtime.onRequest = { [weak self] in self?.handle($0) }
        store.onActivityChange = { [weak self] session, before, after in
            guard let self else { return }
            notifier.activityChanged(session, from: before, to: after)
            refreshBadge(enabled: agents.dockBadge)
            menuBar.refresh()
            notch.refresh()
        }
        menuBar.onSelect = { [weak self] session in
            self?.window?.makeKeyAndOrderFront(nil)
            self?.store.select(session)
        }
        menuBarSwitch = agents.$menuBarStatus.sink { [weak self] in self?.menuBar.setVisible($0) }
        notch.onSelect = menuBar.onSelect
        notchSwitch = agents.$notchStatus.sink { [weak self] in self?.notch.setVisible($0) }
        // A Mac without a notch shows it on the screen edge, whatever was saved.
        notchPlace = agents.$statusPanelPlace.sink { [weak self] in
            let place = NotchStatus.Place(rawValue: $0) ?? .edge
            self?.notch.place = place == .notch && !NotchStatus.isAvailable ? .edge : place
        }
        // A closed session no longer counts toward the lamp.
        sessionsChange = store.$sessions.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.menuBar.refresh()
                self?.notch.refresh()
            }
        }
        styleSwitch = state.$style.dropFirst().sink { [weak self] in self?.applyTheme(style: $0) }
        // @Published reports the new value before the property changes, so pass it along.
        badgeSwitch = agents.$dockBadge.dropFirst().sink { [weak self] in self?.refreshBadge(enabled: $0) }
        notifier.onOpen = { [weak self] id in
            guard let self, let session = self.store.sessions.first(where: { $0.id == id }) else { return }
            self.store.select(session)
        }
        store.onSelectionChange = { [weak self] in
            self?.state.showingSettings = false
            self?.state.showingMerge = false
            self?.show($0)
        }
        // Once git goes on past the last conflict, there is nothing left to show, so the terminal comes back.
        mergeDone = merge.$operation.sink { [weak self] operation in
            guard let self, operation == nil, state.showingMerge else { return }
            DispatchQueue.main.async { self.toggleMerge() }
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
    func newSession(in directory: String? = nil) {
        store.create(directory: directory ?? store.selected?.panes.focused.workingDirectory ?? NSHomeDirectory(), run: agents.startCommand)
    }

    func toggleSidebar() {
        let open = sidebarWidth.constant == 0
        withAnimation(.easeOut(duration: 0.18)) { state.sidebarVisible = open }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            sidebarWidth.animator().constant = open ? SidebarView.width : 0
            layoutGaps(animated: true)
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
            layoutGaps(animated: true)
        }
        followFiles(store.selected)
    }

    /// Opens or closes the git graph. It remembers the choice, and only asks git while open.
    func toggleGraph() {
        let open = !state.graphVisible
        UserDefaults.standard.set(open, forKey: Self.graphVisibleKey)
        let width = open ? clampedGraphWidth(savedGraphWidth) : 0
        withAnimation(.easeOut(duration: 0.18)) {
            state.graphVisible = open
            state.graphWidth = width
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            graphWidth.animator().constant = width
            layoutGaps(animated: true)
        }
        followGraph(store.selected)
    }

    private var savedGraphWidth: CGFloat {
        let saved = UserDefaults.standard.double(forKey: Self.graphWidthKey)
        return saved > 0 ? saved : GraphPanel.defaultWidth
    }

    private func setGraphWidth(_ width: CGFloat) {
        let width = clampedGraphWidth(width)
        graphWidth.constant = width
        state.graphWidth = width
        UserDefaults.standard.set(width, forKey: Self.graphWidthKey)
    }

    /// Room for the terminal stays, however wide the panel is dragged.
    private func clampedGraphWidth(_ width: CGFloat) -> CGFloat {
        let available = (window?.frame.width ?? 1200) - sidebarWidth.constant - filesWidth.constant - reviewWidth.constant - 360
        return min(max(width, 280), max(available, 280))
    }

    /// Text opens in the file pane. Images, PDFs and media open in their Mac app.
    /// Anything else is shown in Finder rather than opened, since opening an unknown binary could run it.
    private func open(_ path: String, line: Int? = nil) {
        let url = URL(fileURLWithPath: path)
        // SVG is an image to macOS, but here it is code you might want to read.
        if let type = UTType(filenameExtension: url.pathExtension), !type.conforms(to: .svg),
           [UTType.image, .pdf, .audiovisualContent].contains(where: type.conforms) {
            NSWorkspace.shared.open(url)
        } else if case .text? = try? Files.read(path) {
            store.selected?.panes.open(path, line: line)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Opens or closes the review panel at the width you last gave it.
    func toggleReview(closing: Bool = false) {
        // Over a commit, "Review changes" brings your changes back. Closing the panel there would hide what you asked for.
        if !closing, review.leaveCommit() { return graph.select(nil) }
        review.isOpen.toggle()
        let saved = UserDefaults.standard.double(forKey: Self.reviewWidthKey)
        let width = review.isOpen ? clampedReviewWidth(saved > 0 ? saved : ReviewPanel.defaultWidth) : 0
        withAnimation(.easeOut(duration: 0.18)) { state.reviewWidth = width }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            reviewWidth.animator().constant = width
            layoutGaps(animated: true)
        }
    }

    private func setReviewWidth(_ width: CGFloat) {
        let width = clampedReviewWidth(width)
        reviewWidth.constant = width
        state.reviewWidth = width
        UserDefaults.standard.set(width, forKey: Self.reviewWidthKey)
    }

    /// Room for the terminal stays, however wide the panel is dragged.
    private func clampedReviewWidth(_ width: CGFloat) -> CGFloat {
        let available = (window?.frame.width ?? 1200) - sidebarWidth.constant - filesWidth.constant - graphWidth.constant - 360
        return min(max(width, 320), max(available, 320))
    }

    private func followReview(_ session: Session?) {
        guard let session else {
            reviewFollow = nil
            return review.follow(nil, branch: nil)
        }
        reviewFollow = session.$topLevel.combineLatest(session.$branch)
            .sink { [weak self] topLevel, branch in self?.review.follow(topLevel, branch: branch) }
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

    private func followGraph(_ session: Session?) {
        guard state.graphVisible, let session else {
            graphFollow = nil
            return graph.show(nil, current: nil)
        }
        graphFollow = session.$topLevel.combineLatest(session.$branch)
            .sink { [weak self] topLevel, branch in self?.graph.show(topLevel, current: branch) }
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

    /// Back to the terminal, with the tests running in a new pane under it. The title bar brings the merge view back.
    private func runAfterMerge(_ command: String) {
        guard let session = store.selected else { return }
        if state.showingMerge { toggleMerge() }
        store.split(session, .down, run: command)
    }

    /// Hands the prompt to an agent. One already running in the session gets it typed in and not sent.
    /// Otherwise a new one starts on it in a pane below. With more than one to pick from, a menu asks which.
    private func askAgent(_ prompt: String) {
        guard let session = store.selected else { return }
        // A pane that once reported is only an agent while something still runs there.
        let running = session.panes.terminals.filter { session.agents[$0.id] != nil && $0.hasRunningProcess }
        var choices: [(title: String, run: () -> Void)] = running.enumerated().map { index, terminal in
            let name = AgentTitle.withoutStatus(terminal.title)
            let title = (name.isEmpty ? "Agent" : name) + (running.count > 1 ? " (pane \(index + 1))" : "")
            return (title, { [weak self] in
                if self?.state.showingMerge == true { self?.toggleMerge() }
                session.panes.focus(terminal)
                terminal.pasteText(prompt)
            })
        }
        choices += AgentFolder.find().map { folder in
            ("Start \(folder.label)", { [weak self] in self?.runAfterMerge(folder.command(task: prompt)) })
        }
        if choices.count == 1 { return choices[0].run() }
        let menu = NSMenu()
        if choices.isEmpty {
            menu.addItem(NSMenuItem(title: "No agent running here, and neither Claude Code nor Codex is set up", action: nil, keyEquivalent: ""))
        } else {
            if !running.isEmpty { menu.addItem(.sectionHeader(title: "Running in this session")) }
            for (index, choice) in choices.enumerated() {
                if index == running.count { menu.addItem(.sectionHeader(title: "Start a new one")) }
                menu.addItem(ActionMenuItem(title: choice.title, handler: choice.run))
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Opens or closes the three column merge view in place of the terminal.
    func commit() { review.askCommit() }

    func push() { review.push() }

    func toggleMerge() {
        guard state.showingMerge || merge.operation != nil else { return }
        state.showingSettings = false
        state.showingMerge.toggle()
        show(store.selected)
    }

    /// Settings hide the session's title, which the list opens under.
    func switchSession() {
        if state.showingSettings { toggleSettings() }
        state.switchingSession.toggle()
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

    /// Asks once per set of problems, so saving again with the same typo stays quiet.
    private func reportConfigErrors() {
        let errors = runtime.configErrors
        defer { settings.configErrors = errors }
        guard !errors.isEmpty, errors != settings.configErrors else { return }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Farol skipped part of your config"
        alert.informativeText = errors.joined(separator: "\n")
            + "\n\nThe rest of the file applies. What was skipped stays in the file until you fix or remove it."
        alert.addButton(withTitle: "Open Config")
        alert.addButton(withTitle: "Later")
        alert.beginSheetModal(for: window) { [settings] response in
            if response == .alertFirstButtonReturn { settings.openFile() }
        }
    }

    private func applyTheme(style: UIStyle? = nil) {
        let bg = runtime.backgroundColor
        state.palette = Palette(runtime, style: style ?? state.style)
        menuBar.apply(state.palette)
        notch.apply(state.palette)
        HoverTip.shared.colors = (bg, runtime.foregroundColor)
        applyStyle()
        window?.appearance = NSAppearance(named: bg.isDark ? .darkAqua : .aqua)
        content.layer?.backgroundColor = bg.cgColor
        store.sessions.forEach {
            $0.panes.theme = theme
            $0.panes.syntax = state.palette.code
        }
    }

    /// Boxed, every panel is a card: round corners, a border, and the backdrop showing in the gaps around it.
    private func applyStyle() {
        let palette = state.palette
        window?.backgroundColor = NSColor(palette.backdrop)
        // The side panels already clip, which a closed one relies on to hide what is in it, so their corners come for free.
        // The terminal stays clear of its card's corners by its own margin, which spares it a mask.
        for panel in panels {
            panel.layer?.cornerRadius = palette.style.radius
            panel.layer?.borderWidth = palette.boxed ? 1 : 0
            panel.layer?.borderColor = NSColor(palette.line).cgColor
        }
        // Settings fills the terminal's card to its edges, so it is cut to the same corners.
        settingsView.layer?.cornerRadius = palette.style.radius
        settingsView.layer?.masksToBounds = palette.boxed
        mergeView.layer?.cornerRadius = palette.style.radius
        mergeView.layer?.masksToBounds = palette.boxed
        layoutGaps()
    }

    /// A closed panel takes no gap, or two gaps would sit side by side where it was.
    private func layoutGaps(animated: Bool = false) {
        let gap = state.palette.style.gap
        let open = [state.sidebarVisible, state.filesVisible, true, state.reviewWidth > 0, state.graphWidth > 0]
        for (constraint, open) in zip(gaps.before, open) {
            (animated ? constraint.animator() : constraint).constant = open ? gap : 0
        }
        gaps.after?.constant = gap
        gaps.under.forEach { $0.constant = gap }
    }

    private var theme: (background: NSColor, foreground: NSColor) { (runtime.backgroundColor, runtime.foregroundColor) }

    private func refreshBadge(enabled: Bool) {
        notifier.updateBadge(waiting: enabled ? store.sessions.filter { [.waiting, .stopped].contains($0.activity) }.count : 0)
    }

    // MARK: Find

    func namePane() { store.selected?.panes.nameFocusedPane() }
    /// The open file when it has focus, else the terminal search.
    private var focusedFile: FileView? {
        guard let panes = store.selected?.panes, panes.fileFocused else { return nil }
        return panes.file
    }

    var canSaveFile: Bool { state.showingMerge ? mergeEditor.mode == .text : focusedFile != nil }

    func saveFile() {
        if state.showingMerge { return mergeEditor.markResolved(merge) }
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
        session.panes.syntax = state.palette.code
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
        let resolving = state.showingMerge && !settings
        settingsView.isHidden = !settings
        mergeView.isHidden = !resolving
        terminalContainer.isHidden = settings || resolving
        for s in store.sessions {
            s.panes.setVisible(!settings && !resolving && s.id == session?.id)
        }
        if resolving {
            window?.makeFirstResponder(mergeEditor.editor.textView)
        } else if !settings, let session {
            window?.makeFirstResponder(session.panes.focusTarget)
        }
        followFiles(session)
        followReview(session)
        followGraph(session)
        followMerge(session)
    }

    private func followMerge(_ session: Session?) {
        guard let session else {
            mergeFollow = nil
            return merge.follow(nil)
        }
        mergeFollow = session.$topLevel.sink { [weak self] in self?.merge.follow($0) }
        // Resolving here changes what the sidebar says about the session, so it reads git again.
        mergeCount = merge.$conflicts.dropFirst().sink { [weak session] _ in session?.refreshGit() }
    }
}
