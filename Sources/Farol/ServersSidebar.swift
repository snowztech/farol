import AppKit
import FarolCore
import FarolRemote
import SwiftUI

/// What the sidebar's servers can ask the window for.
struct ServerCommands {
    let open: (Server, RemoteSession) -> Void
    let newSession: (Server) -> Void
    let add: () -> Void
    /// The terminal a server is setting up in, by its ssh name.
    let showSetup: (String) -> Void
    let retry: (Server) -> Void
    let rename: (Server) -> Void
    let pairPhone: (Server) -> Void
    let remove: (Server) -> Void
}

extension Session.Activity {
    init(_ status: RemoteStatus) {
        switch status {
        case .idle: self = .idle
        case .working: self = .working
        case .waiting: self = .waiting
        case .done: self = .done
        case .stopped: self = .stopped
        }
    }

    /// The one a folded group shows: what most needs you.
    static func loudest(_ all: [Session.Activity]) -> Session.Activity? {
        [.waiting, .stopped, .working, .done].first(where: all.contains)
    }
}

/// Each server you added, after your own sessions, as a group that folds like a project.
struct ServerGroups: View {
    @ObservedObject var servers: ServerLinks
    @ObservedObject var store: SessionStore
    let palette: Palette
    let highlight: Namespace.ID
    let commands: ServerCommands

    @AppStorage("sidebar.foldedServers") private var folded = ""

    var body: some View {
        ForEach(servers.servers) { server in
            let state = servers.state(of: server)
            let shut = isFolded(server)
            ServerHeader(name: server.name, state: state, settingUp: false, folded: shut, palette: palette,
                         onToggle: { toggle(server) }, onNew: { commands.newSession(server) })
                .contextMenu {
                    Button("New Session") { commands.newSession(server) }
                    if state.connection != .connected { Button("Retry") { commands.retry(server) } }
                    Divider()
                    Button("Pair a Phone…") { commands.pairPhone(server) }
                    Button("Rename…") { commands.rename(server) }
                    Button("Remove Server…") { commands.remove(server) }
                }
            if !shut { rows(server, state) }
        }
        // A server being set up has no list yet, so its name holds its place while setup runs in its terminal.
        ForEach(servers.settingUp.filter { ssh in !servers.servers.contains { $0.ssh == ssh } }.sorted(), id: \.self) { ssh in
            ServerHeader(name: Server.name(for: ssh), state: ServerLinks.State(), settingUp: true, folded: false, palette: palette,
                         onToggle: { commands.showSetup(ssh) }, onNew: nil)
            setupRow(ssh)
        }
    }

    /// The terminal setup runs in, so you can watch it or answer a password without hunting for it.
    private func setupRow(_ ssh: String) -> some View {
        ServerSessionRow(session: RemoteSession(id: UUID(), name: "Setting up farol-host", branch: nil, status: .working, asking: nil),
                         detail: ssh,
                         selected: store.selected?.serverWindow == MainWindowController.setupKey(ssh),
                         palette: palette, highlight: highlight) { commands.showSetup(ssh) }
    }

    @ViewBuilder private func rows(_ server: Server, _ state: ServerLinks.State) -> some View {
        // Setting up again, to update farol-host, shows its terminal here too.
        if servers.settingUp.contains(server.ssh) { setupRow(server.ssh) }
        if state.connection == .offline {
            QuietRow(symbol: "arrow.clockwise", text: "Can't reach \(server.name) · Retry", palette: palette) { commands.retry(server) }
        } else if state.connection == .connected && state.sessions.isEmpty {
            QuietRow(symbol: "plus", text: "New session on \(server.name)", palette: palette) { commands.newSession(server) }
        }
        ForEach(state.sessions) { remote in
            let key = remote.window.map { ServerLinks.key(server, $0) }
            ServerSessionRow(session: remote,
                             selected: key != nil && store.selected?.serverWindow == key,
                             palette: palette, highlight: highlight) { commands.open(server, remote) }
        }
    }

    private func isFolded(_ server: Server) -> Bool {
        folded.split(separator: "\n").contains { $0 == server.id.uuidString }
    }

    private func toggle(_ server: Server) {
        var ids = folded.split(separator: "\n").map(String.init)
        if let index = ids.firstIndex(of: server.id.uuidString) { ids.remove(at: index) } else { ids.append(server.id.uuidString) }
        withAnimation(.easeOut(duration: 0.15)) { folded = ids.joined(separator: "\n") }
    }
}

/// A server's name over its sessions. Its icon sits in the lamps' column, and gives way to a lamp when folded.
private struct ServerHeader: View {
    let name: String
    let state: ServerLinks.State
    let settingUp: Bool
    let folded: Bool
    let palette: Palette
    let onToggle: () -> Void
    let onNew: (() -> Void)?

    @State private var hovering = false

    private var offline: Bool { state.connection == .offline && !settingUp }

    var body: some View {
        let loudest = Session.Activity.loudest(state.sessions.map { Session.Activity($0.status) })
        HStack(spacing: 10) {
            ZStack {
                if folded, let loudest {
                    Lamp(activity: loudest, selected: false, palette: palette)
                } else if settingUp || state.connection == .connecting {
                    // Breathing while it connects, so an empty group never reads as a server with nothing on it.
                    ServerIcon(palette: palette).opacity(0.5)
                        .phaseAnimator([false, true]) { icon, bright in icon.opacity(bright ? 1 : 0.4) }
                            animation: { _ in Motion.enabled ? .easeInOut(duration: 0.9) : nil }
                } else {
                    ServerIcon(palette: palette)
                }
            }
            .frame(width: Lamp.size)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? palette.text : palette.muted)
            if let word = settingUp ? "setting up" : offline ? "offline" : nil {
                Text(word).font(.system(size: 11)).foregroundStyle(palette.muted.opacity(0.7))
            } else if folded {
                Text(verbatim: "\(state.sessions.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.muted.opacity(0.7))
            }
            Spacer(minLength: 0)
            if hovering, let onNew, state.connection == .connected {
                CloseButton(symbol: "plus", help: "New session on \(name)", palette: palette, action: onNew)
            }
            if !settingUp {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovering ? palette.text : palette.muted)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .frame(width: 20, height: 20)
                    .opacity(hovering || folded ? 1 : 0.35)
            }
        }
        .lineLimit(1)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onClickableHover { hovering = $0 }
        .hoverTip(settingUp ? "Setting up \(name) in its terminal" : offline ? "\(name) can't be reached" : folded ? "Show \(name)'s sessions" : "Fold \(name)")
        .opacity(offline ? 0.6 : 1)
        .padding(.top, 10)
    }
}

private struct ServerIcon: View {
    let palette: Palette

    var body: some View {
        Image(systemName: "server.rack")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(palette.muted)
    }
}

/// An agent on a server, drawn as your own sessions are, so the lamps read the same wherever they run.
private struct ServerSessionRow: View {
    let session: RemoteSession
    /// A second line of its own, where a session would show its branch.
    var detail: String? = nil
    let selected: Bool
    let palette: Palette
    let highlight: Namespace.ID
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Lamp(activity: Session.Activity(session.status), selected: selected, palette: palette)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? palette.text : palette.text.opacity(0.8))
                    .truncationMode(.tail)
                if let detail {
                    Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted)
                } else if let asking = session.asking, session.status == .waiting {
                    Text(asking).font(.system(size: 11)).foregroundStyle(palette.muted).truncationMode(.tail).hoverTip(asking)
                } else if let branch = session.branch {
                    HStack(spacing: 4) {
                        BranchMark(color: palette.muted)
                        Text(branch).truncationMode(.middle)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.muted)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            if selected {
                shape.fill(palette.selection).overlay(shape.strokeBorder(palette.line))
                    .matchedGeometryEffect(id: "selection", in: highlight)
            } else {
                shape.fill(hovering ? palette.hover : .clear)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onClickableHover { hovering = $0 }
    }
}

/// A quiet line in a group: a way on when there is nothing to show.
private struct QuietRow: View {
    let symbol: String
    let text: String
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).frame(width: Lamp.size)
            Text(text).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(hovering ? palette.text : palette.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onClickableHover { hovering = $0 }
    }
}

/// Add Server: a host from your ssh config, or one you type. Setup then runs in a terminal you can see.
struct AddServerSheet: View {
    let hosts: [String]
    let palette: Palette
    let start: (String) -> Void
    let close: () -> Void

    @State private var typed = ""
    @FocusState private var typing: Bool

    private var host: String { typed.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(title: "Add a server", palette: p) {
                    Text("Its agents show in the sidebar with their status. Farol installs or updates farol-host there over ssh and lets this Mac in.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !hosts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("From ~/.ssh/config").font(.system(size: 12)).foregroundStyle(p.muted)
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(hosts, id: \.self) { host in
                                    SheetChoice(palette: p, choose: { start(host) }) {
                                        Image(systemName: "server.rack").font(.system(size: 11)).foregroundStyle(p.muted)
                                        Text(host)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(hosts.isEmpty ? "Server" : "Or another one").font(.system(size: 12)).foregroundStyle(p.muted)
                    TextField("user@host", text: $typed)
                        .textFieldStyle(.plain)
                        .focused($typing)
                        .onSubmit { if !host.isEmpty { start(host) } }
                        .sheetField(p, focused: typing)
                }
                Text("If ssh asks for a password or sudo, answer it in the terminal that opens.")
                    .font(.system(size: 12))
                    .foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Rectangle().fill(p.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(SheetButton(palette: p, primary: false))
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { start(host) }
                    .buttonStyle(SheetButton(palette: p, primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .frame(width: 420)
        .sheetBackground(p)
        .ignoresSafeArea()
        .onAppear { if hosts.isEmpty { typing = true } }
    }
}
