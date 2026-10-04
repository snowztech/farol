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
    /// Opens a session with a command typed in, for setting up a tool that asks questions.
    let runInTerminal: (String) -> Void

    @AppStorage(AppIcon.key) private var appIcon = AppIcon.default.rawValue
    @AppStorage(SessionStore.groupByRepoKey) private var groupByRepo = false
    @State private var versionCopied = false
    /// One setup per Claude Code and Codex config folder, with each one's state by id.
    @State private var agentSetups: [AgentSetup] = []
    @State private var agentFolders = AgentFolder.find()
    @State private var setups: [String: AgentSetup.State] = [:]
    @State private var agentChange: AgentChange?
    @State private var agentError: String?
    /// Whether gh and glab are there and logged in. Empty while they are being asked.
    @State private var tools: [Forge.Kind: Forge.ToolState] = [:]
    /// Where each connected account's picture is, once known.
    @State private var avatars: [Forge.Kind: URL] = [:]
    /// Whether jira-cli is there and set up. Nil while it is being asked.
    @State private var jira: Forge.ToolState?
    @State private var jiraAvatar: URL?
    @State private var jiraBoards: [Jira.Board] = []
    /// A line that says which board, or empty for your own tickets.
    @AppStorage(Jira.boardKey) private var jiraBoard = ""
    /// macOS refuses Farol's notifications, so turning them on here would do nothing.
    @State private var notificationsBlocked = false

    private struct AgentChange: Identifiable {
        let agent: AgentSetup
        let connect: Bool
        var id: String { agent.id + (connect ? " connect" : " disconnect") }
    }

    @State private var section = Section.terminal
    @State private var themeQuery = ""
    @State private var themes = Theme.all()

    enum Section: String, CaseIterable {
        case terminal = "Terminal"
        case appearance = "Appearance"
        case agents = "Agents"
        case worktrees = "Worktrees"
        case integrations = "Integrations"
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
                        case .integrations: integrationsSection(p)
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
        // The page stays alive while hidden, so coming back from a login in the terminal has to ask again.
        .onChange(of: state.showingSettings) { _, showing in if showing { refreshAgents() } }
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
        .padding(.bottom, 8)

        GroupTitle(title: "Window", palette: p)
        Row(title: "Style",
            detail: "Boxed puts each panel in a rounded card. With color, the panels take a tint of your theme's blue, which also lights what is selected.",
            palette: p) {
            Picker("", selection: $state.style) {
                ForEach(UIStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
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

            ShipButton(title: "Themes folder", busy: false, palette: p, action: openThemesFolder)
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
            toggle($settings.cursorBlink)
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
            toggle($settings.copyOnSelect)
        }

        GroupTitle(title: "Config file", palette: p)
        Row(title: "~/.config/farol/config",
            detail: "Everything on this page is saved here. Add any other option and save, and it applies right away. If you also use Ghostty, its config loads first and Farol's wins.",
            palette: p) {
            ShipButton(title: "Open", busy: false, palette: p, action: settings.openFile)
        }
        ForEach(settings.configErrors, id: \.self) { error in
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(p.waiting)
                .textSelection(.enabled)
                .padding(.top, 6)
        }
    }

    @ViewBuilder private func agentsSection(_ p: Palette) -> some View {
        Heading(title: "Agents", detail: "Set up your coding agents so Farol can tell you when they need you.", palette: p)

        GroupTitle(title: "Status", palette: p)
        ForEach(Array(agentSetups.enumerated()), id: \.element.id) { agentRow($0.element, in: agentFolders[$0.offset], p) }

        GroupTitle(title: "Notifications", palette: p)
        if notificationsBlocked {
            Row(title: "macOS is blocking Farol's notifications",
                detail: "Turn them on for Farol in System Settings, under Notifications.", palette: p) {
                ShipButton(title: "Open System Settings", busy: false, palette: p) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
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
                ForEach(agentFolders, id: \.id) { Text($0.label).tag($0.command()) }
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

    @ViewBuilder private func integrationsSection(_ p: Palette) -> some View {
        Heading(title: "Integrations", detail: "The services Farol works with, through their own command line tools.", palette: p)

        GroupTitle(title: "Pull requests", palette: p)
        Text("Farol creates pull requests and shows their state through these tools. Without them it opens the new request page in your browser.")
            .font(.system(size: 11.5))
            .foregroundStyle(p.muted)
            .padding(.bottom, 4)
        ForEach(Forge.Kind.allCases, id: \.self) { toolRow($0, p) }

        GroupTitle(title: "Tickets", palette: p)
        Text("New Task lists your open Jira tickets, next to the open issues of a repo on GitHub. Picking one names the branch after it and hands the agent the ticket in full.")
            .font(.system(size: 11.5))
            .foregroundStyle(p.muted)
            .padding(.bottom, 4)
        Row(title: "Jira", detail: jiraDetail, icon: ForgeIcon(source: .jira, size: 13), link: ("Jira CLI (jira)", Jira.docs), palette: p) {
            toolControl(jira, avatar: jiraAvatar, setup: Jira.setupCommand(from:), p)
        }
        if listsBoards {
            Row(title: "Tickets to list",
                detail: "Your own open tickets, or everything open on a team's board. A scrum board lists its current sprint.",
                palette: p) {
                Picker("", selection: $jiraBoard) {
                    Text("Assigned to me").tag("")
                    Divider()
                    // The chosen board is listed before the others load, so the picker never shows a blank.
                    ForEach(jiraBoards.isEmpty ? [Jira.Board(line: jiraBoard)].compactMap { $0 } : jiraBoards, id: \.id) { board in
                        Text(board.name).tag(board.line)
                    }
                }
                .labelsHidden()
                // The menu would grow as wide as the longest board's name and squeeze the words beside it.
                .frame(width: 220)
                .disabled(jira == nil)
            }
        }
    }

    /// The board row is there while jira-cli is still being asked, when its config file says it is set up.
    /// Otherwise it would drop in under the Jira row a few seconds after the page opens.
    private var listsBoards: Bool {
        if case .connected = jira { return true }
        return jira == nil && Jira.isSetUp
    }

    private var jiraDetail: String {
        switch jira {
        case nil: "Checking the Jira CLI (jira)…"
        case .connected: "Uses the Jira CLI (jira)."
        case .loggedOut: "The Jira CLI (jira) is installed but not set up. It reads your token from JIRA_API_TOKEN."
        case .missing: "The Jira CLI (jira) isn't installed."
        }
    }

    private func toolRow(_ kind: Forge.Kind, _ p: Palette) -> some View {
        let state = tools[kind]
        // "the GitHub CLI (gh)": the name people know, and the command they would type.
        let cli = "the \(kind.name) CLI (\(kind.tool))"
        let detail = switch state {
        case nil: "Checking \(cli)…"
        case .connected: "Uses \(cli)."
        case .loggedOut: "\(cli.prefix(1).uppercased() + cli.dropFirst()) is installed but not logged in."
        case .missing: "\(cli.prefix(1).uppercased() + cli.dropFirst()) isn't installed."
        }
        return Row(title: kind.name, detail: detail, icon: ForgeIcon(kind: kind, size: 13),
                   link: ("\(kind.name) CLI (\(kind.tool))", kind.docs), palette: p) {
            toolControl(state, avatar: avatars[kind], setup: kind.setupCommand(from:), p)
        }
    }

    /// The right side of a tool's row: its account or state, and a button to set it up when it isn't.
    private func toolControl(_ state: Forge.ToolState?, avatar: URL?, setup: @escaping (Forge.ToolState) -> String,
                             _ p: Palette) -> some View {
        HStack(spacing: 12) {
            if let state {
                if case .connected(let account?) = state {
                    AccountPill(url: avatar, name: account, palette: p)
                } else {
                    ToolStateLabel(state: state, palette: p)
                }
                if state == .missing || state == .loggedOut {
                    // The system's small button reads as switched off in a dark theme, and a filled one shouts for something optional.
                    ShipButton(title: state == .missing ? "Install" : "Log In",
                               help: "Opens a terminal with: \(setup(state))", busy: false, palette: p) {
                        runInTerminal(setup(state))
                    }
                }
            } else {
                // Asking the tool takes a moment, and an empty side would read as nothing found.
                ProgressView().controlSize(.mini)
            }
        }
    }

    private func agentRow(_ agent: AgentSetup, in folder: AgentFolder, _ p: Palette) -> some View {
        let state = setups[agent.id] ?? .disconnected
        // The folder tells accounts apart, so it shows only when an agent has more than one.
        let shared = agentFolders.filter { $0.kind == folder.kind }.count > 1
        let summary = state == .connected ? agent.summaryWhenConnected : agent.summaryWhenDisconnected
        return Row(title: agent.name, subtitle: shared ? (folder.directory.path as NSString).abbreviatingWithTildeInPath : nil, detail: summary, palette: p) {
            HStack(spacing: 12) {
                SetupState(state: state, palette: p)
                switch state {
                case .outdated:
                    ShipButton(title: "Update", busy: false, palette: p) { change(agent, connect: true) }
                case .connected:
                    ShipButton(title: "Disconnect", busy: false, palette: p) { agentChange = AgentChange(agent: agent, connect: false) }
                case .disconnected:
                    ShipButton(title: "Connect", busy: false, palette: p) { agentChange = AgentChange(agent: agent, connect: true) }
                }
            }
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
        !([""] + agentFolders.map { $0.command() }).contains(agents.startCommand)
    }

    /// The picker shows a preset, and "Custom" reveals a field for any other command.
    private var startPreset: Binding<String> {
        Binding(
            get: { isCustomStart ? Self.custom : agents.startCommand },
            set: { agents.startCommand = $0 == Self.custom ? (isCustomStart ? agents.startCommand : " ") : $0 })
    }

    /// Brighter than the pickers' tint, so a switch that is on can't be taken for one that is off.
    private func toggle(_ value: Binding<Bool>) -> some View {
        let p = state.palette
        return Toggle("", isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
            .tint(p.vivid ? p.pull : p.muted)
    }

    private func refreshAgents() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let blocked = settings.authorizationStatus == .denied
            DispatchQueue.main.async { notificationsBlocked = blocked }
        }
        agentFolders = AgentFolder.find()
        agentSetups = AgentSetup.all(folders: agentFolders)
        for agent in agentSetups { setups[agent.id] = agent.state() }
        guard section == .integrations else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let states = Dictionary(uniqueKeysWithValues: Forge.Kind.allCases.map { ($0, $0.toolState()) })
            DispatchQueue.main.async { tools = states }
            let jira = Jira.toolState()
            DispatchQueue.main.async { self.jira = jira }
            // After the states are on screen, since GitLab's picture takes another call to its server.
            var found: [Forge.Kind: URL] = [:]
            for (kind, state) in states {
                if case .connected(let account?) = state { found[kind] = kind.avatar(of: account) }
            }
            let avatars = found
            DispatchQueue.main.async { self.avatars = avatars }
            guard case .connected = jira else { return }
            let picture = Jira.avatar()
            DispatchQueue.main.async { jiraAvatar = picture }
            let boards = Jira.boards()
            DispatchQueue.main.async { jiraBoards = boards }
        }
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
        Text("Rebind the terminal, pane and session ones in the config file, for example keybind = cmd+shift+enter=toggle_split_zoom. Farol's own, like New Task and the panels, are fixed.")
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
            ("Search sessions and files", ["⌘P"]),
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
            ("Commit", ["⌥⌘C"]),
            ("Push", ["⌥⌘P"]),
            ("Git graph", ["⌥⌘G"]),
            ("Resolve conflicts", ["⌥⌘M"]),
            ("Save the open file", ["⌘S"]),
            ("Full screen", ["⌃⌘F", "⌘↩"]),
            ("Settings", ["⌘,"]),
            ("Reload configuration", ["⇧⌘,"]),
            ("Quit", ["⌘Q"]),
        ]),
        ShortcutGroup(title: "Conflicts", items: [
            ("Next and previous change to decide", ["⌥↓", "⌥↑"]),
            ("Accept yours or incoming for the whole file", ["⌃⌘←", "⌃⌘→"]),
            ("Mark the file resolved", ["⌘S"]),
            ("Continue once every file is resolved", ["⌘↩"]),
            ("Back to the terminal", ["esc"]),
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
    /// Muted after the title, like the folder of one of several accounts.
    var subtitle: String? = nil
    var detail: String? = nil
    var icon: ForgeIcon? = nil
    /// Words of the detail that open a page, like a tool's name and its documentation.
    var link: (words: String, url: String)? = nil
    let palette: Palette
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let icon { icon }
                    Text(title).font(.system(size: 13))
                    if let subtitle { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(palette.muted) }
                }
                if let detail {
                    // The link is a view of its own between the words around it. Inside one text it couldn't tell when it is hovered.
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        if let link, let url = URL(string: link.url), let words = detail.range(of: link.words) {
                            Text(detail[..<words.lowerBound])
                            QuietLink(words: link.words, url: url, palette: palette)
                            Text(detail[words.upperBound...])
                        } else {
                            Text(detail)
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.muted)
                }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }
}

/// Words that read as the text around them until the mouse is over them, then as a link.
private struct QuietLink: View {
    let words: String
    let url: URL
    let palette: Palette

    @State private var hovering = false

    var body: some View {
        Link(destination: url) {
            Text(words).underline(hovering).foregroundStyle(hovering ? palette.text : palette.muted)
        }
        .onClickableHover { hovering = $0 }
        .hoverTip(url.host ?? "")
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
                .fill(state == .connected ? palette.done : state == .outdated ? palette.waiting : palette.muted.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(state == .connected ? "Connected" : state == .outdated ? "Needs update" : "Not connected")
                .font(.system(size: 12))
                .foregroundStyle(palette.muted)
        }
    }
}

/// The connected account as one thing: its picture with a green dot on the corner, then its name.
/// The dot stands for "Connected", which the other states spell out since they have no account to show.
private struct AccountPill: View {
    let url: URL?
    let name: String
    let palette: Palette

    var body: some View {
        HStack(spacing: 7) {
            Avatar(url: url, name: name, palette: palette)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(palette.done)
                        .frame(width: 7, height: 7)
                        // A ring in the pill's color, so the dot reads as sitting on the picture.
                        .overlay(Circle().strokeBorder(palette.surface, lineWidth: 1.5).padding(-1.5))
                        .offset(x: 2, y: 2)
                }
            Text(name).font(.system(size: 12, weight: .medium))
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(height: 26)
        .background(palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.line))
        .hoverTip("Connected")
    }
}

/// An account's picture. The slot keeps its size and shows the name's first letter until the picture is there, so the row never shifts.
private struct Avatar: View {
    private static let cache = NSCache<NSURL, NSImage>()
    private static let size: CGFloat = 18

    let url: URL?
    let name: String
    let palette: Palette

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Circle().fill(palette.line)
            Text(name.prefix(1).uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(palette.muted)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).clipShape(Circle())
            }
        }
        .frame(width: Self.size, height: Self.size)
        .task(id: url) { await load() }
    }

    /// A picture loaded before shows at once, with no fade, when you come back to the page.
    private func load() async {
        guard let url else { return }
        if let known = Self.cache.object(forKey: url as NSURL) { return image = known }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let loaded = NSImage(data: data) else { return }
        Self.cache.setObject(loaded, forKey: url as NSURL)
        withAnimation(.easeOut(duration: 0.15)) { image = loaded }
    }
}

/// "Connected" with a green dot, "Not logged in" with a yellow one, or a muted "Not installed".
private struct ToolStateLabel: View {
    let state: Forge.ToolState
    let palette: Palette

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state == .missing ? palette.muted.opacity(0.5) : state == .loggedOut ? palette.waiting : palette.done)
                .frame(width: 6, height: 6)
            Text(state == .missing ? "Not installed" : state == .loggedOut ? "Not logged in" : "Connected")
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
        Button(action: action) { label }
            .buttonStyle(QuietPress())
            .onClickableHover { hovering = $0 }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").font(.system(size: 11.5))
            Text("Open config file").font(.system(size: 12.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(hovering ? palette.text : palette.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
    }
}

private struct Keycap: View {
    let keys: String
    let palette: Palette

    var body: some View {
        Text(keys)
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
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
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? palette.text : palette.muted)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? palette.selection : hovering ? palette.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietPress())
        .onClickableHover { hovering = $0 }
    }
}
