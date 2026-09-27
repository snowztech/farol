import SwiftUI
import GhosttyTerminal

/// Settings live in the window, in place of the terminal, like any other page.
struct SettingsPage: View {
    @ObservedObject var settings: Settings
    @ObservedObject var state: WindowState

    @State private var section = Section.appearance
    @State private var themeQuery = ""

    enum Section: String, CaseIterable {
        case appearance = "Appearance"
        case terminal = "Terminal"
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

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch section {
                    case .appearance: appearance(p)
                    case .terminal: terminal(p)
                    case .shortcuts: shortcuts(p)
                    case .about: about(p)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 28)
                .padding(.bottom, 40)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(p.background)
        .foregroundStyle(p.text)
        .tint(p.accent)
    }

    // MARK: Sections

    @ViewBuilder private func appearance(_ p: Palette) -> some View {
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
        Heading(title: "Farol", detail: "A terminal for working with agents.", palette: p)
        Row(title: "Version", palette: p) {
            Text(Self.version)
                .foregroundStyle(p.muted)
        }
        Row(title: "Terminal engine", palette: p) {
            Text("libghostty").foregroundStyle(p.muted)
        }
    }

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
