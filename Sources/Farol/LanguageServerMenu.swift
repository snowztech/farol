import AppKit
import FarolCore

/// The file's language server menu, the same from the status bar and from a right-click in the code, laid out as Warp's.
/// The project, the server with its state, version and memory, then its logs, restart and stop.
/// Built when it opens, so the memory is read then and not on every redraw.
@MainActor
enum LanguageServerMenu {
    /// `runInTerminal` runs a command in a new terminal pane, for an install that needs you, like one asking for a password.
    static func make(for path: String, openLog: @escaping (String, Int) -> Void, runInTerminal: ((String) -> Void)? = nil) -> NSMenu {
        let servers = LanguageServers.shared
        let menu = NSMenu()
        guard let kind = LSP.server(for: path) else { return menu }
        let server = servers.existing(for: path)
        let installed = servers.isInstalled(kind) != false
        // Not installed, or off for this language: the same shape as when it runs, its state then what to do about it.
        guard installed, servers.isEnabled(kind) else {
            if servers.isInstalling(kind) {
                menu.addItem(title(kind.name, state: "installing", symbol: "arrow.down.circle"))
                return menu
            }
            if !installed, servers.installError(kind) != nil {
                menu.addItem(title(kind.name, state: "couldn't install", symbol: "exclamationmark.triangle"))
                menu.addItem(.separator())
                menu.addItem(action("Show Output", "chevron.left.forwardslash.chevron.right") {
                    let log = servers.installLog(of: kind)
                    openLog(log.path, log.lines)
                })
                menu.addItem(action("Try Again", "arrow.clockwise") { servers.install(kind) })
                if let runInTerminal {
                    menu.addItem(action("Install in Terminal", "terminal") { runInTerminal(kind.install) })
                }
                return menu
            }
            menu.addItem(title(kind.name, state: installed ? "off" : "not installed", symbol: "circle"))
            menu.addItem(.separator())
            if !installed {
                menu.addItem(action("Install Language Server", "arrow.down.circle") { servers.install(kind) })
            } else {
                menu.addItem(action("Enable Language Server", "play.fill") { servers.setEnabled(true, for: kind) })
            }
            return menu
        }
        // The project, once its server has looked up the checkout. Never the file's folder, which reads like one but isn't.
        if let root = server?.root ?? servers.root(for: path) {
            menu.addItem(.sectionHeader(title: (root as NSString).lastPathComponent))
        }
        let loading = server?.state == .starting
        menu.addItem(title(kind.name, state: server.map { Self.state($0.state, loading: loading) } ?? "stopped",
                           symbol: server.map { Self.symbol($0.state, loading: loading) } ?? "circle",
                           details: [server?.version, server?.memory.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) }]))
        menu.addItem(.separator())
        defer {
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(title: "Disable") { servers.setEnabled(false, for: kind) })
        }
        if let server, server.state == .running || server.state == .starting {
            let logs = action("Open Logs", "chevron.left.forwardslash.chevron.right") {
                let log = servers.logFile(of: server)
                openLog(log.path, log.lines)
            }
            logs.isEnabled = !server.log.isEmpty
            menu.addItem(logs)
            menu.addItem(action("Restart Server", "arrow.clockwise") { servers.restart(server) })
            menu.addItem(action("Stop Server", "stop.fill") { servers.stop(server) })
        } else if installed {
            if let server, !server.log.isEmpty {
                menu.addItem(action("Open Logs", "chevron.left.forwardslash.chevron.right") {
                    let log = servers.logFile(of: server)
                    openLog(log.path, log.lines)
                })
            }
            menu.addItem(action("Start Server", "play.fill") { servers.server(for: path) { _ in } })
        } else {
            menu.addItem(action("Copy Install Command", "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(kind.install, forType: .string)
            })
        }
        return menu
    }

    /// The server's name with a gray dot for its state, and after it, muted, what it is doing, its version and memory.
    /// Gray, since a colored dot in Farol is an agent's.
    private static func title(_ name: String, state: String, symbol: String, details: [String?] = []) -> NSMenuItem {
        let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        let text = NSMutableAttributedString(string: name, attributes: [.font: NSFont.menuFont(ofSize: 13)])
        text.append(NSAttributedString(string: "   " + ([state] + details.compactMap { $0 }).joined(separator: " · "),
                                       attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = text
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.isEnabled = false
        return item
    }

    private static func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title: title, handler: run)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    static func state(_ state: LanguageServer.State, loading: Bool) -> String {
        switch state {
        case .starting: "loading project"
        case .running: loading ? "loading project" : "running"
        case .stopped: "stopped"
        case .failed: "stopped with an error"
        }
    }

    static func symbol(_ state: LanguageServer.State, loading: Bool) -> String {
        switch state {
        case .starting: "circle.lefthalf.filled"
        case .running: loading ? "circle.lefthalf.filled" : "circle.fill"
        case .stopped: "circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}
