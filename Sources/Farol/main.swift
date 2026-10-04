import AppKit
import FarolCore
import GhosttyTerminal

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var store: SessionStore!
    private var windowController: MainWindowController!
    private var settings: Settings!
    /// Set once quitting is already decided, so it isn't asked twice.
    private var quitConfirmed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtime = TerminalRuntime(overrideFiles: [Settings.fileURL])
        settings = Settings()
        let agents = AgentSettings()
        settings.onChange = { runtime.reloadConfig() }
        let worktrees = WorktreeSettings()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let socket = support.appendingPathComponent("Farol/\(Bundle.main.bundleIdentifier ?? "farol").sock").path
        store = SessionStore(runtime: runtime, socketPath: socket)
        store.onLastSessionClosed = { [weak self] in
            // Its program was already confirmed or has exited.
            self?.quitConfirmed = true
            NSApp.terminate(nil)
        }
        windowController = MainWindowController(
            store: store, runtime: runtime, settings: settings, agents: agents, worktrees: worktrees)
        NSApp.mainMenu = makeMenu()

        AppIcon.apply()
        windowController.showWindow(nil)
        store.restore()
        NSApp.activate(ignoringOtherApps: true)
        // Reads each agent's config, so it stays off the main thread and out of the launch.
        DispatchQueue.global(qos: .utility).async { AgentSetup.refreshSkills() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitConfirmed { return .terminateNow }
        windowController.confirmQuit { ok in
            self.quitConfirmed = ok
            NSApp.reply(toApplicationShouldTerminate: ok)
        }
        return .terminateLater
    }

    @objc func newSession(_ sender: Any?) { windowController.newSession() }
    @objc func newWorktreeSession(_ sender: Any?) { windowController.newWorktreeSession() }
    @objc func closeSession(_ sender: Any?) { store.selected.map(windowController.requestClosePane) }
    @objc func nextSession(_ sender: Any?) { store.selectNext(offset: 1) }
    @objc func previousSession(_ sender: Any?) { store.selectNext(offset: -1) }
    @objc func selectSession(_ sender: NSMenuItem) { store.select(index: sender.tag) }
    @objc func switchSession(_ sender: Any?) { windowController.switchSession() }

    @objc func toggleSettings(_ sender: Any?) { windowController.toggleSettings() }
    @objc func toggleSidebar(_ sender: Any?) { windowController.toggleSidebar() }
    @objc func toggleFiles(_ sender: Any?) { windowController.toggleFiles() }
    @objc func toggleGraph(_ sender: Any?) { windowController.toggleGraph() }
    @objc func toggleReview(_ sender: Any?) { windowController.toggleReview() }
    @objc func toggleMerge(_ sender: Any?) { windowController.toggleMerge() }
    @objc func commit(_ sender: Any?) { windowController.commit() }
    @objc func push(_ sender: Any?) { windowController.push() }
    @objc func reloadConfig(_ sender: Any?) {
        settings.reload()
        windowController.handle(.reloadConfig)
    }
    @objc func newTask(_ sender: Any?) { windowController.newTask() }
    @objc func namePane(_ sender: Any?) { windowController.namePane() }
    @objc func find(_ sender: Any?) { windowController.find() }
    @objc func findNext(_ sender: Any?) { windowController.findNext() }
    @objc func findPrevious(_ sender: Any?) { windowController.findPrevious() }
    @objc func findSelection(_ sender: Any?) { windowController.findSelection() }
    @objc func saveFile(_ sender: Any?) { windowController.saveFile() }

    /// ⌘S only means something while a file has focus, and stays free for the terminal otherwise.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(saveFile) ? windowController.canSaveFile : true
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(toggleSettings), keyEquivalent: ",")
        // "," with Shift rather than "<", which is only Shift-comma on some layouts, so every keyboard shows ⇧⌘,.
        app.addItem(withTitle: "Reload Configuration", action: #selector(reloadConfig), keyEquivalent: ",")
            .keyEquivalentModifierMask = [.command, .shift]
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Farol", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Farol")

        // nil target: the focused terminal or text field handles these.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let findItems = [
            edit.addItem(withTitle: "Find…", action: #selector(find), keyEquivalent: "f"),
            edit.addItem(withTitle: "Find Next", action: #selector(findNext), keyEquivalent: "g"),
            edit.addItem(withTitle: "Find Previous", action: #selector(findPrevious), keyEquivalent: "G"),
            edit.addItem(withTitle: "Use Selection for Find", action: #selector(findSelection), keyEquivalent: "e"),
        ]
        // Find acts on the session, not on whatever text field has focus.
        findItems.forEach { $0.target = self }
        main.addItem(submenu: edit, title: "Edit")

        let sessions = NSMenu(title: "Session")
        sessions.addItem(withTitle: "New Task…", action: #selector(newTask), keyEquivalent: "N")
        sessions.addItem(withTitle: "New Session", action: #selector(newSession), keyEquivalent: "t")
        sessions.addItem(withTitle: "New Worktree Session…", action: #selector(newWorktreeSession), keyEquivalent: "T")
        sessions.addItem(withTitle: "Close Session", action: #selector(closeSession), keyEquivalent: "w")
        sessions.addItem(withTitle: "Save File", action: #selector(saveFile), keyEquivalent: "s")
        sessions.addItem(withTitle: "Name Pane…", action: #selector(namePane), keyEquivalent: "R")
        sessions.addItem(.separator())
        sessions.addItem(withTitle: "Next Session", action: #selector(nextSession), keyEquivalent: "]")
            .keyEquivalentModifierMask = [.command, .shift]
        sessions.addItem(withTitle: "Previous Session", action: #selector(previousSession), keyEquivalent: "[")
            .keyEquivalentModifierMask = [.command, .shift]
        sessions.addItem(withTitle: "Switch Session…", action: #selector(switchSession), keyEquivalent: "p")
        sessions.addItem(.separator())
        for i in 0..<9 {
            let item = sessions.addItem(withTitle: "Session \(i + 1)", action: #selector(selectSession), keyEquivalent: "\(i + 1)")
            item.tag = i
        }
        main.addItem(submenu: sessions, title: "Session")

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "b")
        view.addItem(withTitle: "Toggle Files", action: #selector(toggleFiles), keyEquivalent: "E")
        view.addItem(withTitle: "Toggle Git Graph", action: #selector(toggleGraph), keyEquivalent: "g")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Review Changes", action: #selector(toggleReview), keyEquivalent: "r")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Commit…", action: #selector(commit), keyEquivalent: "c")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Push", action: #selector(push), keyEquivalent: "p")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Resolve Conflicts", action: #selector(toggleMerge), keyEquivalent: "m")
            .keyEquivalentModifierMask = [.command, .option]
        main.addItem(submenu: view, title: "View")

        for menu in [app, sessions, view] {
            for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
                item.target = self
            }
        }
        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
