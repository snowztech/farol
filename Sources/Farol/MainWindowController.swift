import AppKit
import SwiftUI
import GhosttyTerminal

/// Top bar, session sidebar, and the selected terminal or the settings page.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    /// Same height as the native title bar, so the buttons line up with the traffic lights.
    private static let topBarHeight: CGFloat = 28

    let store: SessionStore
    private let runtime: TerminalRuntime
    private let state: WindowState

    private let content = NSView()
    private let terminalContainer = NSView()
    private var sidebarWidth: NSLayoutConstraint!
    private var settingsView: NSView!

    init(store: SessionStore, runtime: TerminalRuntime, settings: Settings) {
        self.store = store
        self.runtime = runtime
        let base = runtime.ghosttyConfigColors
        self.state = WindowState(
            palette: Palette(background: runtime.backgroundColor, foreground: runtime.foregroundColor, accent: runtime.accentColor),
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
            closeSession: { [weak self] in self?.requestClose($0) },
            toggleSidebar: { [weak self] in self?.toggleSidebar() },
            toggleSettings: { [weak self] in self?.toggleSettings() })

        let root = NSView()
        let topBar = hosting(TopBar(state: state, store: store, commands: commands))
        let sidebar = hosting(SidebarView(store: store, state: state, commands: commands))
        sidebar.clipsToBounds = true
        settingsView = hosting(SettingsPage(settings: settings, state: state))
        settingsView.isHidden = true

        content.wantsLayer = true
        for v in [topBar, sidebar, content] { root.addSubview(v) }
        for v in [terminalContainer, settingsView!] { content.addSubview(v) }
        for v in [topBar, sidebar, content, terminalContainer, settingsView!] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: SidebarView.width)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: Self.topBarHeight),

            sidebar.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth,

            content.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
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
        guard runtime.hasRunningProcesses, let window else { return reply(true) }
        let alert = NSAlert()
        alert.messageText = "Quit Farol?"
        alert.informativeText = "Programs are still running. Quitting stops them."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { reply($0 == .alertFirstButtonReturn) }
    }

    func newSession() { store.create() }

    func toggleSidebar() {
        let open = sidebarWidth.constant == 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            sidebarWidth.animator().constant = open ? SidebarView.width : 0
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
        state.palette = Palette(background: bg, foreground: runtime.foregroundColor, accent: runtime.accentColor)
        window?.backgroundColor = bg
        window?.appearance = NSAppearance(named: bg.isDark ? .darkAqua : .aqua)
        content.layer?.backgroundColor = bg.cgColor
        store.sessions.forEach { $0.panes.theme = theme }
    }

    private var theme: (background: NSColor, foreground: NSColor) { (runtime.backgroundColor, runtime.foregroundColor) }

    // MARK: Find

    func find() { store.selected?.panes.focused.startSearch() }
    func findNext() { store.selected?.panes.searchTarget.searchNext() }
    func findPrevious() { store.selected?.panes.searchTarget.searchPrevious() }
    func findSelection() { store.selected?.panes.focused.searchSelection() }

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
        if !settings, let session { window?.makeFirstResponder(session.panes.focused) }
    }
}
