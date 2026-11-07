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
            retry: { [weak self] in self?.servers.retry($0) },
            rename: { [weak self] in self?.renameServer($0) },
            remove: { [weak self] in self?.removeServer($0) })
    }

    /// From a notification, which only knows the session.
    func openServerSession(id: UUID) {
        for server in servers.servers {
            if let session = servers.state(of: server).sessions.first(where: { $0.id == id }) { return openServerSession(server, session) }
        }
    }

    func openServerSession(_ server: Server, _ session: RemoteSession) {
        guard let window = session.window else {
            return showError("Update farol-host on \(server.name)",
                             "This server's farol-host is too old to open its sessions from the Mac. Run farol-host upgrade there.")
        }
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

    /// Setup runs in a terminal you can see, and Farol pairs as soon as farol-host prints its code there.
    private func setUpServer(_ ssh: String) {
        let session = store.create(run: ServerSetup.command(ssh: ssh, deviceName: ServerLinks.deviceName))
        session.customName = "Setting up \(Server.name(for: ssh))"
        servers.watchSetup(ssh: ssh) { [weak session] in session?.panes.focused.screenText }
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
