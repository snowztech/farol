// PROTOTYPE, throwaway, not for main: what should servers in the sidebar look like? Fake data, three variants.
// Off unless Farol starts with FAROL_PROTOTYPE=servers: open --env FAROL_PROTOTYPE=servers build/Farol.app
import Foundation
import SwiftUI

final class ServersPrototype: ObservableObject {
    static let shared = ServersPrototype()
    static let enabled = ProcessInfo.processInfo.environment["FAROL_PROTOTYPE"] == "servers"

    enum Variant: String, CaseIterable {
        case group = "A", machines = "B", mixed = "C"
        var name: String {
            switch self {
            case .group: "Server groups"
            case .machines: "Machine switcher"
            case .mixed: "Mixed list"
            }
        }
    }

    struct Agent: Identifiable {
        let id = UUID()
        let name: String
        let activity: Session.Activity
        let line: String
    }

    struct Server: Identifiable {
        let id = UUID()
        let name: String
        var connected: Bool
        var agents: [Agent]
    }

    @Published var variant = Variant(rawValue: ProcessInfo.processInfo.environment["FAROL_PROTOTYPE_VARIANT"] ?? "") ?? .group
    @Published var servers: [Server] = [
        Server(name: "hetzner", connected: true, agents: [
            Agent(name: "Refactor the API client", activity: .working, line: "feat/api-client"),
            Agent(name: "Fix the flaky tests", activity: .waiting, line: "Run npm test?"),
            Agent(name: "Update the docs", activity: .done, line: "docs/setup"),
        ]),
        Server(name: "mac-mini", connected: false, agents: []),
    ]
    /// Variant B: nil is this Mac.
    @Published var machine: UUID?
    @Published var adding = false
    @Published var folded: Set<UUID> = []

    func toggleFold(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.15)) {
            if folded.contains(id) { folded.remove(id) } else { folded.insert(id) }
        }
    }

    func cycle(_ step: Int) {
        let all = Variant.allCases
        variant = all[(all.firstIndex(of: variant)! + step + all.count) % all.count]
    }

    /// The real hosts from ~/.ssh/config, so the sheet shows what this Mac would offer.
    static var sshHosts: [String] {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let hosts = text.split(separator: "\n").flatMap { line -> [String] in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard parts.first?.lowercased() == "host" else { return [] }
            return parts.dropFirst().map(String.init).filter { !$0.contains("*") && !$0.contains("?") }
        }
        return hosts.isEmpty ? ["my-vps", "staging"] : hosts
    }
}

// MARK: - Variant A: each server is a group, like a project

struct ServersPrototypeGroups: View {
    @ObservedObject var model = ServersPrototype.shared
    let palette: Palette

    var body: some View {
        ForEach(model.servers) { server in
            let shut = model.folded.contains(server.id)
            ServerHeader(server: server, folded: shut, palette: palette) { model.toggleFold(server.id) }
            if !shut {
                if !server.connected {
                    QuietRow(symbol: "arrow.clockwise", text: "Can't reach \(server.name) · Retry", palette: palette) {}
                } else if server.agents.isEmpty {
                    QuietRow(symbol: "plus", text: "New session on \(server.name)", palette: palette) {}
                }
                ForEach(server.agents) { FakeRow(agent: $0, palette: palette) }
            }
        }
    }
}

private struct ServerHeader: View {
    let server: ServersPrototype.Server
    let folded: Bool
    let palette: Palette
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let activities = server.agents.map(\.activity)
        let loudest = activities.first { $0 == .waiting } ?? activities.first { $0 == .working } ?? activities.first { $0 == .done }
        HStack(spacing: 10) {
            ZStack {
                if folded, let loudest {
                    Lamp(activity: loudest, selected: false, palette: palette)
                } else {
                    Image(systemName: "server.rack")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(palette.muted)
                }
            }
            .frame(width: Lamp.size)
            Text(server.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? palette.text : palette.muted)
            if !server.connected {
                Text("offline").font(.system(size: 11)).foregroundStyle(palette.muted.opacity(0.7))
            } else if folded {
                Text(verbatim: "\(server.agents.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.muted.opacity(0.7))
            }
            Spacer(minLength: 0)
            if hovering {
                CloseButton(symbol: "plus", help: "New session on \(server.name)", palette: palette) {}
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? palette.text : palette.muted)
                .rotationEffect(.degrees(folded ? 0 : 90))
                .frame(width: 20, height: 20)
                .opacity(hovering || folded ? 1 : 0.35)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? palette.hover : .clear))
        .onClickableHover { hovering = $0 }
        .hoverTip(server.connected ? "\(server.name) over ssh, status from farol-host" : "\(server.name) can't be reached")
        .opacity(server.connected ? 1 : 0.6)
        .padding(.top, 10)
    }
}

// MARK: - Variant B: pick a machine at the top, see only its sessions

struct ServersPrototypeMachines: View {
    @ObservedObject var model = ServersPrototype.shared
    let localActivities: [Session.Activity]
    let palette: Palette

    var body: some View {
        HStack(spacing: 4) {
            chip(name: "This Mac", symbol: "laptopcomputer", activities: localActivities, id: nil)
            ForEach(model.servers) { server in
                chip(name: server.name, symbol: "server.rack", activities: server.agents.map(\.activity), id: server.id)
                    .opacity(server.connected ? 1 : 0.5)
            }
            CloseButton(symbol: "plus", help: "Add Server", palette: palette) { model.adding = true }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private func chip(name: String, symbol: String, activities: [Session.Activity], id: UUID?) -> some View {
        let on = model.machine == id
        let loudest = activities.first { $0 == .waiting } ?? activities.first { $0 == .working } ?? activities.first { $0 == .done }
        return HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(name).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1)
            if let loudest { Lamp(activity: loudest, selected: on, palette: palette) }
        }
        .foregroundStyle(on ? palette.text : palette.muted)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? palette.selection : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.machine = id }
    }
}

struct ServersPrototypeMachineList: View {
    @ObservedObject var model = ServersPrototype.shared
    let palette: Palette

    var body: some View {
        if let server = model.servers.first(where: { $0.id == model.machine }) {
            if server.agents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack").font(.system(size: 20)).foregroundStyle(palette.muted)
                    Text(server.connected ? "No sessions on \(server.name)" : "\(server.name) can't be reached")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text)
                    QuietRow(symbol: "plus", text: "New session", palette: palette) {}.fixedSize()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            }
            ForEach(server.agents) { FakeRow(agent: $0, palette: palette) }
        }
    }
}

// MARK: - Variant C: one list, a server's sessions carry its name

struct ServersPrototypeMixed: View {
    @ObservedObject var model = ServersPrototype.shared
    let palette: Palette

    var body: some View {
        ForEach(model.servers) { server in
            ForEach(server.agents) { FakeRow(agent: $0, host: server.name, palette: palette) }
        }
    }
}

/// Variant C keeps the sidebar as it is, so adding a server sits in the + menu with the other ways to start.
struct ServersPrototypeNewMenu: View {
    @ObservedObject var model = ServersPrototype.shared
    let palette: Palette

    var body: some View {
        Menu {
            Button("New Session") {}
            Button("New Task…") {}
            Divider()
            Menu("New Session on Server") {
                ForEach(model.servers) { Button($0.name) {} }
            }
            Button("Add Server…") { model.adding = true }
        } label: {
            Label("New", systemImage: "plus").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(palette.muted)
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared rows

private struct FakeRow: View {
    let agent: ServersPrototype.Agent
    var host: String? = nil
    let palette: Palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Lamp(activity: agent.activity, selected: false, palette: palette)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(agent.name).font(.system(size: 13)).foregroundStyle(palette.text.opacity(0.8))
                        .lineLimit(1).truncationMode(.tail)
                    if let host {
                        Badge(text: host, small: true, palette: palette).layoutPriority(1)
                    }
                }
                HStack(spacing: 4) {
                    if agent.activity != .waiting { BranchMark(color: palette.muted) }
                    Text(agent.line).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11, design: agent.activity == .waiting ? .default : .monospaced))
                .foregroundStyle(palette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? palette.hover : .clear))
        .onClickableHover { hovering = $0 }
    }
}

private struct QuietRow: View {
    let symbol: String
    let text: String
    let palette: Palette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium)).frame(width: Lamp.size)
            Text(text).font(.system(size: 12))
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

// MARK: - Add Server sheet, shared by every variant

struct ServersPrototypeAddSheet: View {
    @ObservedObject var model = ServersPrototype.shared
    let palette: Palette

    @State private var picked: String?
    @State private var typed = ""
    @State private var log: [String] = []
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(picked.map { "Connecting \($0)" } ?? "Add Server").font(.system(size: 15, weight: .semibold))
            if let picked {
                Text("Farol installs farol-host over ssh and pairs this Mac. A password or sudo prompt would show here.")
                    .font(.system(size: 12)).foregroundStyle(palette.muted)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(log, id: \.self) { Text($0) }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.text.opacity(0.85))
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
                HStack {
                    Spacer()
                    Button(finished ? "Done" : "Cancel") {
                        if finished {
                            model.servers.append(.init(name: picked, connected: true, agents: []))
                        }
                        model.adding = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Pick a host from ~/.ssh/config, or type user@host. Its agents show in the sidebar with their status.")
                    .font(.system(size: 12)).foregroundStyle(palette.muted)
                VStack(spacing: 2) {
                    ForEach(ServersPrototype.sshHosts, id: \.self) { host in
                        QuietRow(symbol: "server.rack", text: host, palette: palette) { connect(host) }
                    }
                }
                TextField("user@host", text: $typed).onSubmit { if !typed.isEmpty { connect(typed) } }
                HStack {
                    Spacer()
                    Button("Cancel") { model.adding = false }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func connect(_ host: String) {
        picked = host
        let steps = ["$ ssh \(host)", "Installing farol-host into ~/.local/bin", "tmux 3.4 found",
                     "Connecting Claude Code and Codex hooks", "Starting farol-host with systemd", "Pairing this Mac", "\(host) is connected"]
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.5) {
                log.append(step)
                if index == steps.count - 1 { finished = true }
            }
        }
    }
}

/// Variant A: Add Server sits beside New task at the foot of the sidebar, always in the same place.
struct ServersPrototypeAddButton: View {
    @ObservedObject var model = ServersPrototype.shared
    let palette: Palette

    var body: some View {
        CloseButton(symbol: "server.rack", help: "Add Server", palette: palette) { model.adding = true }
    }
}

// MARK: - Floating switcher, only while the prototype is on

struct ServersPrototypeSwitcher: View {
    @ObservedObject var model = ServersPrototype.shared

    var body: some View {
        HStack(spacing: 10) {
            Button { model.cycle(-1) } label: { Image(systemName: "chevron.left") }
            Text("\(model.variant.rawValue) · \(model.variant.name)").font(.system(size: 11, weight: .semibold))
            Button { model.cycle(1) } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.yellow))
        .shadow(radius: 4)
        .padding(.bottom, 6)
    }
}
