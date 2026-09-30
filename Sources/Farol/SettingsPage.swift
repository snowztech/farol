import FarolCore
import SwiftUI
import UserNotifications
import GhosttyTerminal

/// Settings live in the window, in place of the terminal, like any other page.
struct SettingsPage: View {
    @ObservedObject var settings: Settings
    @ObservedObject var agents: AgentSettings
    @ObservedObject var worktrees: WorktreeSettings
    @ObservedObject var state: WindowState
    @ObservedObject var updates: UpdateChecker

    @AppStorage(AppIcon.key) private var appIcon = AppIcon.default.rawValue
    @AppStorage(SessionStore.groupByRepoKey) private var groupByRepo = false
    @State private var versionCopied = false
    /// Each agent's setup state, by name.
    @State private var setups: [String: AgentSetup.State] = [:]
    @State private var agentChange: AgentChange?
    @State private var agentError: String?
    /// macOS refuses Farol's notifications, so turning them on here would do nothing.
    @State private var notificationsBlocked = false

    private struct AgentChange: Identifiable {
        let agent: AgentSetup
        let connect: Bool
        var id: String { agent.name + (connect ? " connect" : " disconnect") }
    }

    @State private var section = Section.terminal
    @State private var themeQuery = ""
    @State private var themes = Theme.all()

    enum Section: String, CaseIterable {
        case terminal = "Terminal"
        case appearance = "Appearance"
        case agents = "Agents"
        case worktrees = "Worktrees"
        case shortcuts = "Shortcuts"
        case about = "About"
    }

    var body: some View {
        let p = state.palette
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Section.allCases, id: \.self) { s in
                    NavItem(title: s.rawValue, selected: s == section, palette: p) { section = s }
                }
                Spacer()
                OpenConfigRow(palette: p, action: settings.openFile)
                    .padding(.bottom, 12)
            }
            .padding(.top, 28)
            .padding(.horizontal, 10)
            .frame(width: 180)

            Rectangle().fill(p.line).frame(width: 1)

            if section == .about {
                // A centered identity block rather than a scrolling list.
                about(p).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch section {
                        case .appearance: appearance(p)
                        case .terminal: terminal(p)
                        case .agents: agentsSection(p)
                        case .worktrees: worktreesSection(p)
                        case .shortcuts: shortcuts(p)
                        case .about: EmptyView()
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 28)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 820, alignment: .leading)
                    // Centered in whatever room there is, so hiding the sidebar doesn't leave an empty strip on the right.
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(p.background)
        .foregroundStyle(p.text)
        .tint(p.control)
        .onAppear(perform: refreshAgents)
        .onChange(of: section) { _, _ in refreshAgents() }
        .alert(item: $agentChange, content: agentAlert)
        .onChange(of: appIcon) { _, name in AppIcon.apply(AppIcon(rawValue: name) ?? .default) }
    }

    // MARK: Sections

    @ViewBuilder private func appearance(_ p: Palette) -> some View {
        Heading(title: "Appearance", detail: nil, palette: p)
        Row(title: "App icon", detail: "Shown in the Dock while Farol runs.", palette: p) {
            Picker("", selection: $appIcon) {
                ForEach(AppIcon.allCases, id: \.self) { icon in
                    Label {
                        Text(icon == .default ? "\(icon.title) (default)" : icon.title)
                    } icon: {
                        if let image = icon.menuImage { Image(nsImage: image) }
                    }
                    .tag(icon.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.bottom, 8)

        GroupTitle(title: "Sidebar", palette: p)
        Row(title: "Group sessions by project",
            detail: "Sessions in the same git repository, worktrees included, go under one header once you work in more than one.",
            palette: p) {
            toggle($groupByRepo)
        }
        .padding(.bottom, 32)

        Heading(title: "Theme",
                detail: "Applies to every session as soon as you pick it. To add your own, drop a Ghostty theme file in the themes folder.",
                palette: p)
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(p.muted)
                TextField("Search \(themes.filter { $0.url != nil }.count) themes", text: $themeQuery)
                    .textFieldStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.line))

            Button("Themes folder", action: openThemesFolder)
        }
        .padding(.bottom, 20)

        ThemeGallery(query: themeQuery, selected: $settings.theme,
                     ghosttyConfig: state.ghosttyConfigPreview, palette: p, themes: themes)
            // Picks up themes added while Farol runs.
            .onAppear { themes = Theme.all() }
    }

    private func openThemesFolder() {
        try? FileManager.default.createDirectory(at: Theme.userDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Theme.userDirectory)
    }

    @ViewBuilder private func terminal(_ p: Palette) -> some View {
        Heading(title: "Terminal", detail: "Applies to every session.", palette: p)

        GroupTitle(title: "Font", palette: p)
        Row(title: "Family", palette: p) {
            Picker("", selection: $settings.fontFamily) {
                Text("Default").tag("")
                ForEach(Settings.monospacedFamilies, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        Row(title: "Size", palette: p) {
            Stepper("\(settings.fontSize) pt", value: $settings.fontSize, in: 8...32)
        }

        GroupTitle(title: "Cursor", palette: p)
        Row(title: "Style", palette: p) {
            Picker("", selection: $settings.cursorStyle) {
                Text("Block").tag("block")
                Text("Bar").tag("bar")
                Text("Underline").tag("underline")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
        Row(title: "Blink", palette: p) {
            Toggle("", isOn: $settings.cursorBlink).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }

        GroupTitle(title: "Keyboard and mouse", palette: p)
        Row(title: "Option key as Alt",
            detail: "For shortcuts in programs like vim or emacs. Leave it off to type accents with Option.",
            palette: p) {
            Picker("", selection: $settings.optionAsAlt) {
                Text("Off").tag("false")
                Text("Left").tag("left")
                Text("Right").tag("right")
                Text("Both").tag("true")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
        Row(title: "Copy on select", detail: "Selecting text copies it to the clipboard.", palette: p) {
            Toggle("", isOn: $settings.copyOnSelect).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }

        GroupTitle(title: "Config file", palette: p)
        Row(title: "~/.config/farol/config",
            detail: "Everything on this page is saved here. Add any other option and save, and it applies right away. If you also use Ghostty, its config loads first and Farol's wins.",
            palette: p) {
            Button("Open", action: settings.openFile)
        }
    }

    @ViewBuilder private func agentsSection(_ p: Palette) -> some View {
        Heading(title: "Agents", detail: "Set up your coding agents so Farol can tell you when they need you.", palette: p)

        GroupTitle(title: "Integrations", palette: p)
        ForEach(AgentSetup.all, id: \.name) { agentRow($0, p) }

        GroupTitle(title: "Notifications", palette: p)
        if notificationsBlocked {
            Row(title: "macOS is blocking Farol's notifications",
                detail: "Turn them on for Farol in System Settings, under Notifications.", palette: p) {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        Row(title: "When an agent is waiting for you", palette: p) { toggle($agents.notifyWaiting) }
        Row(title: "When an agent finishes", palette: p) { toggle($agents.notifyDone) }
        Row(title: "Waiting count on the Dock icon", palette: p) { toggle($agents.dockBadge) }

        GroupTitle(title: "Outside Farol", palette: p)
        Row(title: "In the menu bar", detail: "See agents working, waiting or done from any app, and jump to a session.", palette: p) {
            toggle($agents.menuBarStatus)
        }
        Row(title: "Status panel", detail: "A small black panel while agents are active. Hover it to see the sessions.", palette: p) {
            Picker("", selection: statusPanel) {
                Text("Off").tag("off")
                if NotchStatus.isAvailable { Text("At the notch").tag(NotchStatus.Place.notch.rawValue) }
                Text("On the screen edge").tag(NotchStatus.Place.edge.rawValue)
            }
            .labelsHidden()
            .fixedSize()
        }

        GroupTitle(title: "New sessions", palette: p)
        Row(title: "Start with", detail: "Typed into the shell of every new session, so you are back in the shell when it exits.", palette: p) {
            Picker("", selection: startPreset) {
                Text("Shell").tag("")
                Text("Claude Code").tag("claude")
                Text("Codex").tag("codex")
                Text("Custom").tag(Self.custom)
            }
            .labelsHidden()
            .fixedSize()
        }
        if isCustomStart {
            Row(title: "Command", palette: p) {
                TextField("For example aider", text: $agents.startCommand)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }
        if let agentError {
            Text(agentError)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .padding(.top, 12)
        }
    }

    @ViewBuilder private func worktreesSection(_ p: Palette) -> some View {
        Heading(title: "Worktrees", detail: "Applies to new tasks and worktree sessions.", palette: p)

        GroupTitle(title: "Local environment", palette: p)
        Row(title: "Copy local environment files",
            detail: "Copies ignored .env files into each new worktree so projects can run immediately. Agents in the worktree can read their values.",
            palette: p) {
            toggle($worktrees.copyEnvironmentFiles)
        }
    }

    private func agentRow(_ agent: AgentSetup, _ p: Palette) -> some View {
        let state = setups[agent.name] ?? .disconnected
        let summary = state == .connected ? agent.summaryWhenConnected : agent.summaryWhenDisconnected
        return Row(title: agent.name, detail: summary, palette: p) {
            HStack(spacing: 12) {
                SetupState(state: state, palette: p)
                switch state {
                case .outdated:
                    Button("Update") { change(agent, connect: true) }
                case .connected:
                    Button("Disconnect") { agentChange = AgentChange(agent: agent, connect: false) }
                case .disconnected:
                    Button("Connect") { agentChange = AgentChange(agent: agent, connect: true) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func agentAlert(_ change: AgentChange) -> Alert {
        let agent = change.agent
        guard change.connect else {
            return Alert(
                title: Text("Disconnect \(agent.name)?"),
                message: Text(agent.disconnectMessage),
                primaryButton: .destructive(Text("Disconnect")) { self.change(agent, connect: false) },
                secondaryButton: .cancel())
        }
        return Alert(
            title: Text("Connect \(agent.name)?"),
            message: Text(agent.connectMessage),
            primaryButton: .default(Text("Connect")) { self.change(agent, connect: true) },
            secondaryButton: .cancel())
    }

    /// Off, or where the status panel shows. A notch choice on a Mac without one reads as the screen edge.
    private var statusPanel: Binding<String> {
        Binding(
            get: {
                guard agents.notchStatus else { return "off" }
                return agents.statusPanelPlace == NotchStatus.Place.notch.rawValue && !NotchStatus.isAvailable
                    ? NotchStatus.Place.edge.rawValue : agents.statusPanelPlace
            },
            set: { value in
                if value == "off" { return agents.notchStatus = false }
                agents.statusPanelPlace = value
                agents.notchStatus = true
            })
    }

    private static let custom = "custom"

    private var isCustomStart: Bool {
        !["", "claude", "codex"].contains(agents.startCommand)
    }

    /// The picker shows a preset, and "Custom" reveals a field for any other command.
    private var startPreset: Binding<String> {
        Binding(
            get: { isCustomStart ? Self.custom : agents.startCommand },
            set: { agents.startCommand = $0 == Self.custom ? (isCustomStart ? agents.startCommand : " ") : $0 })
    }

    private func toggle(_ value: Binding<Bool>) -> some View {
        Toggle("", isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }

    private func refreshAgents() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let blocked = settings.authorizationStatus == .denied
            DispatchQueue.main.async { notificationsBlocked = blocked }
        }
        for agent in AgentSetup.all { setups[agent.name] = agent.state() }
    }

    private func change(_ agent: AgentSetup, connect: Bool) {
        do {
            try connect ? agent.connect() : agent.disconnect()
            agentError = nil
            // Asked here, while you are looking, rather than at the first notification when you are away.
            if connect {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                    DispatchQueue.main.async { refreshAgents() }
                }
            }
        } catch {
            let path = (agent.file.path as NSString).abbreviatingWithTildeInPath
            agentError = "Could not update \(path): \(error.localizedDescription)"
        }
        refreshAgents()
    }

    @ViewBuilder private func shortcuts(_ p: Palette) -> some View {
        Heading(title: "Shortcuts", detail: "Standard terminal shortcuts, plus Farol's own for sessions.", palette: p)
        ForEach(Self.shortcutGroups, id: \.title) { group in
            GroupTitle(title: group.title, palette: p)
            ForEach(group.items, id: \.action) { item in
                Row(title: item.action, palette: p) {
                    HStack(spacing: 4) {
                        ForEach(item.keys, id: \.self) { Keycap(keys: $0, palette: p) }
                    }
                }
            }
        }
        Text("Rebind any of them in the config file, for example keybind = cmd+shift+enter=toggle_split_zoom.")
            .font(.system(size: 12))
            .foregroundStyle(p.muted)
            .padding(.top, 20)
    }

    @ViewBuilder private func about(_ p: Palette) -> some View {
        VStack(spacing: 0) {
            if let image = (AppIcon(rawValue: appIcon) ?? .default).image {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: 112, height: 112)
            }
            Text("Farol")
                .font(.system(size: 26, weight: .semibold))
                .padding(.top, 8)
            Text("A terminal for working with agents.")
                .font(.system(size: 13))
                .foregroundStyle(p.muted)
                .padding(.top, 4)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.version, forType: .string)
                versionCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { versionCopied = false }
            } label: {
                HStack(spacing: 6) {
                    Text("Version \(Self.version)").font(.system(size: 12, design: .monospaced))
                    Image(systemName: versionCopied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5))
                }
                .foregroundStyle(p.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(p.raised, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .onClickableHover { _ in }
            .hoverTip("Copy the version")
            .padding(.top, 20)

            if let version = updates.available {
                Button("Farol \(version) is available. Download it.", action: updates.install)
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .tint(p.text)
                    .onClickableHover { _ in }
                    .padding(.top, 10)
            }

            HStack(spacing: 18) {
                link("GitHub", Self.repo)
                link("Changelog", Self.repo + "/blob/main/CHANGELOG.md")
                link("Report an issue", Self.repo + "/issues/new")
            }
            .font(.system(size: 12.5))
            .padding(.top, 24)

            // The string literal is read as Markdown, so snowztech becomes a quiet link in the same line.
            Text("Built on libghostty. © 2026 Lucas Neves Pereira, [snowztech](https://github.com/snowztech)")
                .font(.system(size: 11))
                .foregroundStyle(p.muted.opacity(0.8))
                .tint(p.muted)
                .padding(.top, 28)
        }
        .padding(40)
    }

    private func link(_ title: String, _ url: String) -> some View {
        Link(title, destination: URL(string: url)!)
            .foregroundStyle(state.palette.text)
            .onClickableHover { _ in }
    }

    private static let repo = "https://github.com/snowztech/farol"

    /// Set by scripts/bundle.sh from the latest git tag.
    private static let version = Bundle.main.object(forInfoDictionaryKey: "FarolVersion") as? String ?? "dev"

    private struct ShortcutGroup {
        let title: String
        let items: [(action: String, keys: [String])]
    }

    private static let shortcutGroups = [
        ShortcutGroup(title: "Sessions", items: [
            ("New task", ["⇧⌘N"]),
            ("New session", ["⌘T", "⌘N"]),
            ("New worktree session", ["⇧⌘T"]),
            ("Close pane or session", ["⌘W"]),
            ("Next and previous session", ["⇧⌘]", "⇧⌘["]),
            ("Go to session 1 to 9", ["⌘1…⌘9"]),
        ]),
        ShortcutGroup(title: "Panes", items: [
            ("Split right", ["⌘D"]),
            ("Split down", ["⇧⌘D"]),
            ("Next and previous pane", ["⌘]", "⌘["]),
            ("Move to the pane in a direction", ["⌥⌘ arrows"]),
            ("Resize the focused pane", ["⌃⌘ arrows"]),
            ("Make panes equal", ["⌃⌘="]),
            ("Zoom the focused pane", ["⇧⌘↩"]),
            ("Name the focused pane", ["⇧⌘R"]),
        ]),
        ShortcutGroup(title: "Find", items: [
            ("Find", ["⌘F"]),
            ("Next and previous match", ["⌘G", "⇧⌘G"]),
            ("Find the selected text", ["⌘E"]),
            ("Close find", ["esc"]),
        ]),
        ShortcutGroup(title: "Terminal", items: [
            ("Copy, paste, select all", ["⌘C", "⌘V", "⌘A"]),
            ("Clear the screen", ["⌘K"]),
            ("Bigger, smaller, reset text", ["⌘+", "⌘−", "⌘0"]),
            ("Previous and next prompt", ["⌘↑", "⌘↓"]),
            ("Scroll to top and bottom", ["⌘Home", "⌘End"]),
            ("Scroll a page", ["⌘Page Up", "⌘Page Down"]),
            ("Start and end of line", ["⌘←", "⌘→"]),
            ("Previous and next word", ["⌥←", "⌥→"]),
            ("Delete to start of line", ["⌘⌫"]),
        ]),
        ShortcutGroup(title: "Window", items: [
            ("Toggle sidebar", ["⌘B"]),
            ("Toggle files", ["⇧⌘E"]),
            ("Review changes", ["⌥⌘R"]),
            ("Git graph", ["⌥⌘G"]),
            ("Save the open file", ["⌘S"]),
            ("Full screen", ["⌃⌘F", "⌘↩"]),
            ("Settings", ["⌘,"]),
            ("Reload configuration", ["⇧⌘,"]),
            ("Quit", ["⌘Q"]),
        ]),
    ]
}

private struct Heading: View {
    let title: String
    let detail: String?
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 20, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 12.5)).foregroundStyle(palette.muted)
            }
        }
        .padding(.bottom, 20)
    }
}

private struct Row<Control: View>: View {
    let title: String
    var detail: String? = nil
    let palette: Palette
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(palette.muted)
                }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }
}

/// A small heading between rows. Sentence case, a step above the rows, no rule of its own.
private struct GroupTitle: View {
    let title: String
    let palette: Palette

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.muted)
            .padding(.top, 22)
            .padding(.bottom, 2)
    }
}

/// "Connected" with a green dot, "Needs update" with a yellow one, or a muted "Not connected".
private struct SetupState: View {
    let state: AgentSetup.State
    let palette: Palette

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state == .connected ? Color.green : state == .outdated ? Color.yellow : palette.muted.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(state == .connected ? "Connected" : state == .outdated ? "Needs update" : "Not connected")
                .font(.system(size: 12))
                .foregroundStyle(palette.muted)
        }
    }
}

/// Pinned under the settings sections, and styled like New task under the sessions.
private struct OpenConfigRow: View {
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").font(.system(size: 11.5))
            Text("Open config file").font(.system(size: 12.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(hovering ? palette.text : palette.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? palette.raised.opacity(0.35) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onClickableHover { hovering = $0 }
    }
}

private struct Keycap: View {
    let keys: String
    let palette: Palette

    var body: some View {
        Text(keys)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(palette.raised, in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct NavItem: View {
    let title: String
    let selected: Bool
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Capsule()
                    .fill(selected ? palette.accent : .clear)
                    .frame(width: 2.5, height: 14)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? palette.text : palette.muted)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.trailing, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering && !selected ? palette.raised.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onClickableHover { hovering = $0 }
    }
}
