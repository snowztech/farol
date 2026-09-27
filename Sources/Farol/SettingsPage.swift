import FarolCore
import SwiftUI
import GhosttyTerminal

/// Settings live in the window, in place of the terminal, like any other page.
struct SettingsPage: View {
    @ObservedObject var settings: Settings
    @ObservedObject var agents: AgentSettings
    @ObservedObject var state: WindowState

    @AppStorage(AppIcon.key) private var appIcon = AppIcon.default.rawValue
    @State private var claudeConnected = false
    @State private var versionCopied = false
    @State private var claudeConfirm: ClaudeChange?
    @State private var claudeError: String?

    private enum ClaudeChange: Identifiable {
        case connect, disconnect
        var id: Self { self }
    }

    @State private var section = Section.terminal
    @State private var themeQuery = ""

    enum Section: String, CaseIterable {
        case terminal = "Terminal"
        case appearance = "Appearance"
        case agents = "Agents"
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
                Button(action: settings.openFile) {
                    Label("Open config file", systemImage: "doc.text")
                        .font(.system(size: 12))
                        .foregroundStyle(p.muted)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
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
        .onAppear(perform: refreshClaude)
        .onChange(of: section) { _, _ in refreshClaude() }
        .alert(item: $claudeConfirm, content: claudeAlert)
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
        .padding(.bottom, 32)


        Heading(title: "Theme", detail: "Applies to every session as soon as you pick it.", palette: p)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(p.muted)
            TextField("Search \(Self.themeCount) themes", text: $themeQuery)
                .textFieldStyle(.plain)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.line))
        .padding(.bottom, 20)

        ThemeGallery(query: themeQuery, selected: $settings.theme,
                     ghosttyConfig: state.ghosttyConfigPreview, palette: p)
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

        Text("Anything else Ghostty supports can go in the config file. Your Ghostty config loads first, and these settings override it.")
            .font(.system(size: 12))
            .foregroundStyle(p.muted)
            .padding(.top, 20)
    }

    @ViewBuilder private func agentsSection(_ p: Palette) -> some View {
        Heading(title: "Agents", detail: "Connect your coding agents so the sidebar shows what they are doing.", palette: p)

        GroupTitle(title: "Integrations", palette: p)
        Row(title: "Claude Code",
            detail: claudeConnected
                ? "The sidebar shows when Claude is working, waiting for you or done."
                : "Show in the sidebar when Claude is working, waiting for you or done.",
            palette: p) {
            HStack(spacing: 12) {
                ConnectionState(connected: claudeConnected, palette: p)
                if claudeConnected {
                    Button("Disconnect") { claudeConfirm = .disconnect }
                        .buttonStyle(.bordered)
                } else {
                    Button("Connect") { claudeConfirm = .connect }
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
        }

        GroupTitle(title: "Notifications", palette: p)
        Row(title: "When an agent is waiting for you", palette: p) { toggle($agents.notifyWaiting) }
        Row(title: "When an agent finishes", palette: p) { toggle($agents.notifyDone) }
        Row(title: "Waiting count on the Dock icon", palette: p) { toggle($agents.dockBadge) }

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
        if let claudeError {
            Text(claudeError)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .padding(.top, 12)
        }
    }

    private func claudeAlert(_ change: ClaudeChange) -> Alert {
        switch change {
        case .connect:
            Alert(
                title: Text("Connect Claude Code?"),
                message: Text("Farol adds hooks for five events to ~/.claude/settings.json. Your other settings stay as they are, though the file may be reformatted. The current file is kept as settings.json.farol-backup."),
                primaryButton: .default(Text("Connect")) { changeClaude(ClaudeHooks.install) },
                secondaryButton: .cancel())
        case .disconnect:
            Alert(
                title: Text("Disconnect Claude Code?"),
                message: Text("Farol removes only its own hooks from ~/.claude/settings.json and keeps a backup of the file."),
                primaryButton: .destructive(Text("Disconnect")) { changeClaude(ClaudeHooks.remove) },
                secondaryButton: .cancel())
        }
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

    private func refreshClaude() {
        claudeConnected = (try? ClaudeHooks.read()).map(ClaudeHooks.isInstalled) ?? false
    }

    private func changeClaude(_ change: ([String: Any]) -> [String: Any]) {
        do {
            try ClaudeHooks.write(change(try ClaudeHooks.read()))
            claudeError = nil
        } catch {
            claudeError = "Could not update ~/.claude/settings.json: \(error.localizedDescription)"
        }
        refreshClaude()
    }

    @ViewBuilder private func shortcuts(_ p: Palette) -> some View {
        Heading(title: "Shortcuts", detail: "Ghostty's defaults, plus Farol's own for sessions.", palette: p)
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
            .help("Copy the version")
            .padding(.top, 20)

            HStack(spacing: 18) {
                link("GitHub", Self.repo)
                link("Changelog", Self.repo + "/blob/main/CHANGELOG.md")
                link("Report an issue", Self.repo + "/issues/new")
            }
            .font(.system(size: 12.5))
            .padding(.top, 24)

            Link(destination: URL(string: "https://github.com/snowztech")!) {
                Text("A snowztech project").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(p.muted)
            .padding(.top, 32)

            Text("Built on libghostty. Copyright 2026 Lucas Neves Pereira.")
                .font(.system(size: 11))
                .foregroundStyle(p.muted.opacity(0.8))
                .padding(.top, 6)
        }
        .padding(40)
    }

    private func link(_ title: String, _ url: String) -> some View {
        Link(title, destination: URL(string: url)!).foregroundStyle(state.palette.text)
    }

    private static let repo = "https://github.com/snowztech/farol"

    private static let themeCount = TerminalRuntime.bundledThemes.count

    /// Set by scripts/bundle.sh from the latest git tag.
    private static let version = Bundle.main.object(forInfoDictionaryKey: "FarolVersion") as? String ?? "dev"

    private struct ShortcutGroup {
        let title: String
        let items: [(action: String, keys: [String])]
    }

    private static let shortcutGroups = [
        ShortcutGroup(title: "Sessions", items: [
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

/// "Connected" with a green dot, or a muted "Not connected".
private struct ConnectionState: View {
    let connected: Bool
    let palette: Palette

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connected ? Color.green : palette.muted.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(connected ? "Connected" : "Not connected")
                .font(.system(size: 12))
                .foregroundStyle(palette.muted)
        }
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
        .onHover { hovering = $0 }
    }
}
