import AppKit
import GhosttyTerminal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SessionStore!
    private var windowController: MainWindowController!
    private var settings: Settings!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtime = TerminalRuntime(overrideFiles: [Settings.fileURL])
        settings = Settings()
        settings.onChange = { runtime.reloadConfig() }
        store = SessionStore(runtime: runtime)
        store.onLastSessionClosed = { NSApp.terminate(nil) }
        windowController = MainWindowController(store: store, runtime: runtime, settings: settings)
        NSApp.mainMenu = makeMenu()

        windowController.showWindow(nil)
        store.create()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func newSession(_ sender: Any?) { windowController.newSession() }
    @objc func closeSession(_ sender: Any?) { store.selected.map(store.close) }
    @objc func nextSession(_ sender: Any?) { store.selectNext(offset: 1) }
    @objc func previousSession(_ sender: Any?) { store.selectNext(offset: -1) }
    @objc func selectSession(_ sender: NSMenuItem) { store.select(index: sender.tag) }

    @objc func toggleSettings(_ sender: Any?) { windowController.toggleSettings() }
    @objc func toggleSidebar(_ sender: Any?) { windowController.toggleSidebar() }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(toggleSettings), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Farol", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Farol")

        let sessions = NSMenu(title: "Session")
        sessions.addItem(withTitle: "New Session", action: #selector(newSession), keyEquivalent: "t")
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
