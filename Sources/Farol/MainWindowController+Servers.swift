import AppKit
import FarolCore
import FarolRemote
import SwiftUI

extension MainWindowController {
    var serverCommands: ServerCommands {
        ServerCommands(
            open: { [weak self] in self?.openServerSession($0, $1) },
            newSession: { [weak self] in self?.newServerSession(on: $0) },
            add: { [weak self] in self?.addServer() },
            showSetup: { [weak self] ssh in
                guard let self, let setup = store.sessions.first(where: { $0.serverWindow == Self.setupKey(ssh) }) else { return }
                store.select(setup)
            },
            retry: { [weak self] in self?.servers.retry($0) },
            rename: { [weak self] in self?.renameServer($0) },
            pairPhone: { [weak self] in self?.pairPhone(with: $0) },
            remove: { [weak self] in self?.removeServer($0) })
    }

    /// From a notification, which only knows the session.
    func openServerSession(id: UUID) {
        for server in servers.servers {
            if let session = servers.state(of: server).sessions.first(where: { $0.id == id }) { return openServerSession(server, session) }
        }
    }

    func openServerSession(_ server: Server, _ session: RemoteSession) {
        guard let window = session.window else { return askToUpdate(server) }
        openServerWindow(server, window)
    }

    /// One Farol session per tmux window: opening it again goes back to the one already open.
    private func openServerWindow(_ server: Server, _ window: String) {
        let key = ServerLinks.key(server, window)
        if let open = store.sessions.first(where: { $0.serverWindow == key }) { return store.select(open) }
        // exec, so leaving tmux closes the session instead of dropping back to a shell on this Mac.
        store.create(run: "exec " + ServerSetup.attach(ssh: server.ssh, window: window), serverWindow: key)
    }

    /// A new tmux session on the server, made first without a terminal so the one opened next knows its window.
    /// ssh that needs a password can't answer without one, so that case opens a plain ssh session instead.
    private func newServerSession(on server: Server) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ssh = Process()
            ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            ssh.arguments = ServerSetup.newWindowArguments(ssh: server.ssh)
            let output = Pipe()
            ssh.standardOutput = output
            ssh.standardError = FileHandle.nullDevice
            ssh.standardInput = FileHandle.nullDevice
            try? ssh.run()
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            ssh.waitUntilExit()
            let made = ssh.terminationStatus == 0
                ? String(decoding: printed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                if let window = made, ServerSetup.isWindow(window) { return self.openServerWindow(server, window) }
                self.store.create(run: ServerSetup.newSession(ssh: server.ssh))
            }
        }
    }

    func addServer() {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        let close = { [weak window, weak sheet] in sheet.map { window?.endSheet($0) } }
        let view = AddServerSheet(hosts: ServerSetup.sshHosts, palette: state.palette, start: { [weak self] ssh in
            close()
            self?.setUpServer(ssh)
        }, close: { close() })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }

    static func setupKey(_ ssh: String) -> String { "setup " + ssh }

    /// Setup runs in a terminal you can see, under the server in the sidebar, and closes once the server trusts this Mac.
    /// Run again on a server already added, it upgrades farol-host there.
    private func setUpServer(_ ssh: String) {
        guard let key = servers.publicKey else {
            return showError("Farol couldn't read its key", "Allow Farol to use the Keychain when macOS asks, then add the server again.")
        }
        store.sessions.filter { $0.serverWindow == Self.setupKey(ssh) }.forEach { store.close($0) }
        let session = store.create(run: ServerSetup.command(ssh: ssh, deviceKey: key, deviceName: ServerLinks.deviceName),
                                   serverWindow: Self.setupKey(ssh))
        servers.watchSetup(ssh: ssh) { [weak self, weak session] in
            guard let self, let session, store.sessions.contains(where: { $0 === session }) else { return nil }
            return session.panes.focused.title
        }
    }

    func setUpFinished(_ ssh: String) {
        store.sessions.filter { $0.serverWindow == Self.setupKey(ssh) }.forEach { store.close($0) }
    }

    private func askToUpdate(_ server: Server) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Update farol-host on \(server.name)"
        alert.informativeText = "Its farol-host is too old to open sessions from the Mac. Farol can install the latest one over ssh."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.setUpServer(server.ssh) }
        }
    }

    /// The server's phone code in a sheet. Without ssh that runs on its own, the code shows in a terminal instead.
    private func pairPhone(with server: Server) {
        if state.showingSettings { toggleSettings() }
        guard let window, window.attachedSheet == nil else { return }
        let pairing = PhonePairing(server: server)
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        let close = { [weak window, weak sheet] in
            pairing.stop()
            sheet.map { window?.endSheet($0) }
        }
        let view = PairPhoneSheet(server: server, pairing: pairing, palette: state.palette, openTerminal: { [weak self] in
            self?.store.create(run: ServerSetup.pairInTerminal(ssh: server.ssh))
        }, close: { close() })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }

    private func renameServer(_ server: Server) {
        guard let window else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = server.name
        let alert = NSAlert()
        alert.messageText = "Rename \(server.name)"
        alert.informativeText = "The name the sidebar and notifications use. ssh still connects to \(server.ssh)."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.servers.rename(server, to: field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    func removeServer(_ server: Server) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(server.name)?"
        alert.informativeText = "Its agents leave the sidebar and the server stops letting this Mac in. They keep running there, and your phone still sees them."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            for session in store.sessions where session.serverWindow?.hasPrefix(server.id.uuidString) == true { store.close(session) }
            servers.remove(server)
        }
    }
}
