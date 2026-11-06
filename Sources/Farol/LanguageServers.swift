import AppKit
import FarolCore

/// The language servers Farol runs, each turned on per language and off by default, so Farol stays as light as ever unless you want them.
/// A server starts when a file of its language comes to the front, one per checkout, and stops after a while unused.
@MainActor
final class LanguageServers {
    static let shared = LanguageServers()
    static func enabledKey(_ server: LSP.Server) -> String { "code.languageServers." + server.command }
    /// A server started, stopped or changed state, for the file pane and Settings.
    static let didChange = Notification.Name("FarolLanguageServersDidChange")
    /// A language was turned on, so the file in front can start its server without waiting to be opened again.
    static let didTurnOn = Notification.Name("FarolLanguageServersDidTurnOn")

    func isEnabled(_ server: LSP.Server) -> Bool { UserDefaults.standard.bool(forKey: Self.enabledKey(server)) }

    /// Whether the file's language has a server and it is turned on.
    func isEnabled(for path: String) -> Bool { LSP.server(for: path).map(isEnabled) ?? false }

    func setEnabled(_ on: Bool, for server: LSP.Server) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey(server))
        if !on {
            for (key, running) in running where running.server == server {
                running.stop()
                self.running[key] = nil
            }
        }
        changed()
        if on { NotificationCenter.default.post(name: Self.didTurnOn, object: nil) }
    }

    /// By checkout and server, since gopls for one worktree knows nothing of another's.
    private var running: [String: LanguageServer] = [:]
    /// The checkout a folder is in, asked of git once per folder.
    private var tops: [String: String] = [:]
    /// Where each server's command is, or nil when it isn't installed. Looked for once, and again after Settings changes.
    private var executables: [String: String?] = [:]
    private var idleTimer: Timer?
    /// Unused this long, a server stops. Many agent worktrees would otherwise each keep one in memory.
    private static let idleLimit: TimeInterval = 10 * 60

    /// The server for a file, started if needed, or nil when the setting is off, its language has none, or it isn't installed.
    func server(for path: String, then done: @escaping (LanguageServer?) -> Void) {
        guard let server = LSP.server(for: path), isEnabled(server) else { return done(nil) }
        let directory = (path as NSString).deletingLastPathComponent
        if let root = tops[directory], let executable = executables[server.command] {
            return done(running(server, root: root, executable: executable))
        }
        let known = executables[server.command]
        DispatchQueue.global(qos: .userInitiated).async {
            let root = Git.topLevel(of: directory) ?? directory
            let executable = known ?? LSP.locate(server.command, in: LSP.searchPath)
            DispatchQueue.main.async {
                self.tops[directory] = root
                self.executables[server.command] = executable
                done(self.running(server, root: root, executable: executable))
            }
        }
    }

    /// The server for a file only if one is already there, for the footer, which never starts one.
    func existing(for path: String) -> LanguageServer? {
        guard let server = LSP.server(for: path), let root = tops[(path as NSString).deletingLastPathComponent] else { return nil }
        return running[key(server, root)]
    }

    /// Where a server's command was found, or nil when it wasn't, or before anyone looked.
    func location(of server: LSP.Server) -> String? {
        executables[server.command] ?? nil
    }

    /// The servers running for a checkout, by name, for the status bar's menu.
    func running(in root: String) -> [LanguageServer] {
        running.values.filter { $0.root == root }.sorted { $0.server.name < $1.server.name }
    }

    /// The checkout a file is in, once known.
    func root(for path: String) -> String? {
        tops[(path as NSString).deletingLastPathComponent]
    }

    /// The project a file's server runs for, named after its checkout, once known.
    func project(for path: String) -> String? {
        tops[(path as NSString).deletingLastPathComponent].map { ($0 as NSString).lastPathComponent }
    }

    /// Whether a server's command was found, or nil before anyone looked.
    func isInstalled(_ server: LSP.Server) -> Bool? {
        executables[server.command].map { $0 != nil }
    }

    /// Looks again for a server that wasn't found, at most every few seconds, so one installed from Farol is noticed without a restart.
    func recheck(_ server: LSP.Server, then done: @escaping () -> Void) {
        guard isInstalled(server) == false, Date().timeIntervalSince(lastRecheck) > 5 else { return }
        lastRecheck = Date()
        locateAll(then: done)
    }
    private var lastRecheck = Date.distantPast

    /// Looks for every server again, as after installing one from Settings.
    func locateAll(then done: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = LSP.servers.map { ($0.command, LSP.locate($0.command, in: LSP.searchPath)) }
            DispatchQueue.main.async {
                for (command, path) in found { self.executables[command] = path }
                done()
            }
        }
    }

    /// Stops it and starts a fresh one for the same checkout, as after changing its settings or when it got stuck.
    func restart(_ server: LanguageServer) {
        server.stop()
        running[key(server.server, server.root)] = nil
        _ = running(server.server, root: server.root, executable: executables[server.server.command] ?? nil)
        changed()
    }

    func stop(_ server: LanguageServer) {
        server.stop()
        running[key(server.server, server.root)] = nil
        changed()
    }

    /// The server's log written to ~/Library/Logs/Farol, to open in a tab like any file. Returns its path and line count.
    func logFile(of server: LanguageServer) -> (path: String, lines: Int) {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Farol")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(server.server.name) \((server.root as NSString).lastPathComponent).log")
        try? (server.log.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return (file.path, max(1, server.log.count))
    }

    func close(_ path: String) {
        existing(for: path)?.close(path)
    }

    private func running(_ server: LSP.Server, root: String, executable: String?) -> LanguageServer? {
        guard let executable else { return nil }
        let key = key(server, root)
        if let found = running[key] { return found }
        let started = LanguageServer(server: server, root: root)
        started.onStateChange = { [weak self] in self?.changed() }
        running[key] = started
        started.start(executable: executable)
        watchIdle()
        changed()
        return started
    }

    /// Checks once a minute while any server runs, and not at all otherwise.
    private func watchIdle() {
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.stopIdle() }
        }
    }

    private func stopIdle() {
        for (key, server) in running where Date().timeIntervalSince(server.lastUsed) > Self.idleLimit {
            server.stop()
            running[key] = nil
        }
        if running.isEmpty {
            idleTimer?.invalidate()
            idleTimer = nil
        }
        changed()
    }

    private func key(_ server: LSP.Server, _ root: String) -> String { server.command + "\0" + root }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
