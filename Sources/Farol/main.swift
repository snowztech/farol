import AppKit
import GhosttyTerminal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SessionStore!
    private var windowController: MainWindowController!
    private var settings: Settings!
    /// Set once quitting is already decided, so it isn't asked twice.
    private var quitConfirmed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtime = TerminalRuntime(overrideFiles: [Settings.fileURL])
        settings = Settings()
        settings.onChange = { runtime.reloadConfig() }
        store = SessionStore(runtime: runtime)
        store.onLastSessionClosed = { [weak self] in
            // Its program was already confirmed or has exited.
            self?.quitConfirmed = true
            NSApp.terminate(nil)
        }
        windowController = MainWindowController(store: store, runtime: runtime, settings: settings)
        NSApp.mainMenu = makeMenu()

        windowController.showWindow(nil)
        store.restore()
        NSApp.activate(ignoringOtherApps: true)
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

    @objc func toggleSettings(_ sender: Any?) { windowController.toggleSettings() }
    @objc func toggleSidebar(_ sender: Any?) { windowController.toggleSidebar() }
    @objc func reloadConfig(_ sender: Any?) { windowController.handle(.reloadConfig) }
    @objc func find(_ sender: Any?) { windowController.find() }
    @objc func findNext(_ sender: Any?) { windowController.findNext() }
    @objc func findPrevious(_ sender: Any?) { windowController.findPrevious() }
    @objc func findSelection(_ sender: Any?) { windowController.findSelection() }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(toggleSettings), keyEquivalent: ",")
        app.addItem(withTitle: "Reload Configuration", action: #selector(reloadConfig), keyEquivalent: "<")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Farol", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Farol")

        // nil target: the focused terminal or text field handles these.
        let edit = NSMenu(title: "Edit")
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
        sessions.addItem(withTitle: "New Session", action: #selector(newSession), keyEquivalent: "t")
        sessions.addItem(withTitle: "New Worktree Session…", action: #selector(newWorktreeSession), keyEquivalent: "T")
        sessions.addItem(withTitle: "Close Session", action: #selector(closeSession), keyEquivalent: "w")
        sessions.addItem(.separator())
        sessions.addItem(withTitle: "Next Session", action: #selector(nextSession), keyEquivalent: "]")
            .keyEquivalentModifierMask = [.command, .shift]
        sessions.addItem(withTitle: "Previous Session", action: #selector(previousSession), keyEquivalent: "[")
            .keyEquivalentModifierMask = [.command, .shift]
        sessions.addItem(.separator())
        for i in 0..<9 {
            let item = sessions.addItem(withTitle: "Session \(i + 1)", action: #selector(selectSession), keyEquivalent: "\(i + 1)")
            item.tag = i
        }
        main.addItem(submenu: sessions, title: "Session")

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "b")
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
