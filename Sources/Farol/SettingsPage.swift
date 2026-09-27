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
        Heading(title: "Terminal", detail: "Font and cursor for every session.", palette: p)
        Row(title: "Font", palette: p) {
            Picker("", selection: $settings.fontFamily) {
                Text("Default").tag("")
                ForEach(Settings.monospacedFamilies, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 220)
        }
        Row(title: "Size", palette: p) {
            Stepper("\(settings.fontSize) pt", value: $settings.fontSize, in: 8...32)
        }
        Row(title: "Cursor", palette: p) {
            Picker("", selection: $settings.cursorStyle) {
                Text("Block").tag("block")
                Text("Bar").tag("bar")
                Text("Underline").tag("underline")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
        Text("Anything else Ghostty supports can go in the config file. Your Ghostty config loads first; Farol's settings win.")
            .font(.system(size: 12))
            .foregroundStyle(p.muted)
            .padding(.top, 16)
    }

    @ViewBuilder private func shortcuts(_ p: Palette) -> some View {
        Heading(title: "Shortcuts", detail: nil, palette: p)
        ForEach(Self.shortcutList, id: \.0) { action, keys in
            Row(title: action, palette: p) {
                Text(keys)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(p.raised, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    @ViewBuilder private func about(_ p: Palette) -> some View {
        Heading(title: "Farol", detail: "A terminal for working with agents.", palette: p)
        Row(title: "Version", palette: p) {
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                .foregroundStyle(p.muted)
        }
        Row(title: "Terminal engine", palette: p) {
            Text("libghostty").foregroundStyle(p.muted)
        }
    }

    private static let themeCount = TerminalRuntime.bundledThemes.count

    private static let shortcutList = [
        ("New session", "⌘T"),
        ("Close session", "⌘W"),
        ("Next session", "⇧⌘]"),
        ("Previous session", "⇧⌘["),
        ("Go to session 1–9", "⌘1 – ⌘9"),
        ("Toggle sidebar", "⌘B"),
        ("Settings", "⌘,"),
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
    let palette: Palette
    @ViewBuilder let control: Control

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            control
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
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
