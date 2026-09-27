import AppKit
import SwiftUI
import GhosttyTerminal

/// Top bar, session sidebar, and the selected terminal or the settings page.
final class MainWindowController: NSWindowController {
    /// Same height as the native title bar, so the buttons line up with the traffic lights.
    private static let topBarHeight: CGFloat = 28

    private let store: SessionStore
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

        let commands = Commands(
            newSession: { [weak self] in self?.newSession() },
            toggleSidebar: { [weak self] in self?.toggleSidebar() },
            toggleSettings: { [weak self] in self?.toggleSettings() })

        let root = NSView()
        let topBar = hosting(TopBar(state: state, store: store, commands: commands))
        let sidebar = hosting(SidebarView(store: store, state: state))
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
        store.onSessionCreated = { [weak self] in self?.host($0.terminal) }
        store.onSelectionChange = { [weak self] in
            self?.state.showingSettings = false
            self?.show($0)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Commands

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
    }

    private func host(_ terminal: TerminalView) {
        terminal.frame = terminalContainer.bounds
        terminal.autoresizingMask = [.width, .height]
        terminalContainer.addSubview(terminal)
    }

    /// Only the terminal on screen renders. Settings replaces it and pauses it too.
    private func show(_ session: Session?) {
        let settings = state.showingSettings
        settingsView.isHidden = !settings
        terminalContainer.isHidden = settings
        for s in store.sessions {
            s.terminal.setVisible(!settings && s.id == session?.id)
        }
        if !settings, let session { window?.makeFirstResponder(session.terminal) }
    }
}
