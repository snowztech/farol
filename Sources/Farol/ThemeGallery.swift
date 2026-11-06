import SwiftUI
import GhosttyTerminal

/// The colors a preview card needs, read straight from a Ghostty theme file.
struct ThemeColors {
    let background: Color
    let foreground: Color
    let cursor: Color
    let ansi: [Color]
    /// A light background, for the gallery's Dark and Light filter.
    var isLight = false

    /// Ghostty's default ANSI colors, for themes that leave some out.
    private static let defaultANSI = ["1d1f21", "cc6666", "b5bd68", "f0c674", "81a2be", "b294bb", "8abeb7", "c5c8c6"]
        .map { Color(hex: $0)! }

    /// Preview for the user's Ghostty config, which only says its background and foreground.
    init(background: NSColor, foreground: NSColor) {
        self.background = Color(nsColor: background)
        self.foreground = Color(nsColor: foreground)
        cursor = self.foreground
        ansi = Self.defaultANSI
        isLight = (background.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.5
    }

    init(background: Color, foreground: Color, cursor: Color, ansi: [Color]) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.ansi = ansi
    }

    private static var cache: [String: ThemeColors] = [:]

    static func load(_ url: URL) -> ThemeColors {
        if let cached = cache[url.path] { return cached }

        var values: [String: String] = [:]
        var palette: [Int: Color] = [:]
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "palette" {
                // "palette = 4=#81a2be"
                let entry = parts[1].split(separator: "=", maxSplits: 1)
                if entry.count == 2, let i = Int(entry[0]), let c = Color(hex: String(entry[1])) { palette[i] = c }
            } else {
                values[parts[0]] = parts[1]
            }
        }

        let bg = values["background"].flatMap(Color.init(hex:)) ?? .black
        let fg = values["foreground"].flatMap(Color.init(hex:)) ?? .white
        var colors = ThemeColors(
            background: bg,
            foreground: fg,
            cursor: values["cursor-color"].flatMap(Color.init(hex:)) ?? fg,
            ansi: (0..<8).map { palette[$0] ?? defaultANSI[$0] })
        colors.isLight = values["background"].flatMap { NSColor(Color(hex: $0) ?? .black).usingColorSpace(.sRGB)?.brightnessComponent }.map { $0 > 0.5 } ?? false
        cache[url.path] = colors
        return colors
    }
}

/// One card in the gallery. `value` is what goes after `theme =` in the config file.
struct Theme: Hashable {
    let name: String
    let value: String
    let url: URL?

    static let userDirectory = Settings.fileURL.deletingLastPathComponent().appendingPathComponent("themes")

    /// Farol's own. The first is in use until a theme is picked, unless your Ghostty config sets its own colors.
    static let farol = ["Farol Beam", "Farol Dark", "Farol Fog", "Farol Navy", "Farol Dusk", "Farol Ember", "Farol Dawn", "Farol Light"]

    /// A hand pick of well known themes from Ghostty's set, not a count of anything, with light ones so the Light filter keeps some.
    /// One missing from a later Ghostty is left out.
    static let popular = [
        "Catppuccin Mocha", "TokyoNight", "Dracula", "Gruvbox Dark", "Nord", "Rose Pine",
        "Kanagawa Wave", "Atom One Dark", "Catppuccin Latte", "Rose Pine Dawn", "GitHub Light Default", "Everforest Light Med",
    ]

    /// Farol's themes, then yours, then Ghostty's. Yours are set by full path, since Ghostty only looks for names in its own folders.
    static func all() -> [Theme] {
        let user = ((try? FileManager.default.contentsOfDirectory(atPath: userDirectory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { name -> Theme in
                let url = userDirectory.appendingPathComponent(name)
                return Theme(name: name, value: url.path, url: url)
            }
        let bundled = { (name: String) in
            Theme(name: name, value: name, url: TerminalRuntime.themesDirectory?.appendingPathComponent(name))
        }
        return farol.map(bundled) + user + TerminalRuntime.bundledThemes.filter { !farol.contains($0) }.map(bundled)
    }

    /// Your Ghostty config's colors as a card, when it sets any. The theme in use until you pick one.
    static let ghosttyColors = Theme(name: "Your Ghostty colors", value: "", url: nil)

    /// What goes after `theme =` now: the pick, or with none, your Ghostty colors when they exist and Farol Beam otherwise.
    static func current(_ picked: String, ghosttyConfig: ThemeColors?) -> String {
        !picked.isEmpty ? picked : ghosttyConfig == nil ? farol[0] : ""
    }

    func colors(_ ghosttyConfig: ThemeColors?) -> ThemeColors {
        url.map(ThemeColors.load) ?? ghosttyConfig ?? ThemeColors(background: .black, foreground: .white)
    }
}

/// The theme in use, above the gallery, so you see what you're on before looking through the rest.
struct CurrentTheme: View {
    let picked: String
    let ghosttyConfig: ThemeColors?
    let themes: [Theme]
    let palette: Palette

    var body: some View {
        let value = Theme.current(picked, ghosttyConfig: ghosttyConfig)
        let theme = value.isEmpty ? Theme.ghosttyColors
            : themes.first { $0.value == value } ?? Theme(name: (value as NSString).lastPathComponent, value: value, url: nil)
        Card(palette: palette) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Current theme").font(.system(size: 12)).foregroundStyle(palette.muted)
                    Text(theme.name).font(.system(size: 15, weight: .semibold))
                }
                Spacer(minLength: 16)
                ThemePreview(colors: theme.colors(ghosttyConfig), hues: theme.url != nil)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line))
                    .frame(width: 200)
            }
            .padding(.vertical, 12)
        }
    }
}

struct ThemeGallery: View {
    let query: String
    @Binding var selected: String
    /// Nil when your Ghostty config sets no colors of its own.
    let ghosttyConfig: ThemeColors?
    let palette: Palette

    let themes: [Theme]
    let tone: ThemeTone

    var body: some View {
        let matching = cards.filter(matches)
        let farol = matching.filter { Theme.farol.contains($0.value) }
        // Your Ghostty config's colors are yours too, next to the themes in your folder.
        let yours = matching.filter { $0.value.isEmpty || $0.value.hasPrefix("/") }
        let popular = Theme.popular.compactMap { name in matching.first { $0.value == name } }
        let more = matching.filter { !farol.contains($0) && !yours.contains($0) && !popular.contains($0) }
        VStack(alignment: .leading, spacing: 0) {
            if matching.isEmpty {
                Text("No themes match.").font(.system(size: 12)).foregroundStyle(palette.muted)
            }
            section("Farol", farol)
            section("Yours", yours)
            section("Popular", popular)
            section("More themes", more)
        }
    }

    @ViewBuilder private func section(_ title: String, _ themes: [Theme]) -> some View {
        if !themes.isEmpty {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.muted)
                .padding(.bottom, 8)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: 14)], spacing: 18) {
                ForEach(themes, id: \.self) { theme in
                    // Your Ghostty colors are only a background and a foreground, so no hues are made up for them.
                    ThemeCard(name: theme.name, colors: theme.colors(ghosttyConfig), hues: theme.url != nil,
                              selected: theme.value == current, palette: palette)
                        .onTapGesture { selected = theme.value }
                }
            }
            .padding(.bottom, 26)
        }
    }

    private func matches(_ theme: Theme) -> Bool {
        guard query.isEmpty || theme.name.localizedCaseInsensitiveContains(query) else { return false }
        return switch tone {
        case .all: true
        case .dark: !theme.colors(ghosttyConfig).isLight
        case .light: theme.colors(ghosttyConfig).isLight
        }
    }

    private var current: String { Theme.current(selected, ghosttyConfig: ghosttyConfig) }

    private var cards: [Theme] { (ghosttyConfig == nil ? [] : [Theme.ghosttyColors]) + themes }
}

/// The gallery's filter, since people browse for a dark theme or a light one.
enum ThemeTone: String, CaseIterable {
    case all = "All", dark = "Dark", light = "Light"
}

/// All, Dark and Light, drawn like the search field and the button beside it. A native segmented control's rounder shape and own cursor sat oddly in that row.
struct ToneSwitch: View {
    @Binding var tone: ThemeTone
    let palette: Palette

    @Namespace private var pill
    @State private var hovering: ThemeTone?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ThemeTone.allCases, id: \.self) { option in
                Button {
                    withAnimation(Motion.enabled ? .easeOut(duration: 0.15) : nil) { tone = option }
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 13, weight: option == tone ? .medium : .regular))
                        .foregroundStyle(option == tone || hovering == option ? palette.text : palette.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background {
                            if option == tone {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(palette.selection)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuietPress())
                .onClickableHover { hovering = $0 ? option : (hovering == option ? nil : hovering) }
            }
        }
        .padding(3)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line))
        .fixedSize()
    }
}

private struct ThemeCard: View {
    let name: String
    let colors: ThemeColors
    let hues: Bool
    let selected: Bool
    let palette: Palette

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ThemePreview(colors: colors, hues: hues)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? palette.accent : hovering ? palette.muted : palette.line,
                                      lineWidth: selected ? 2 : 1))

            Text(name)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? palette.text : palette.muted)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onClickableHover { hovering = $0 }
    }
}

/// A few lines of a terminal in a theme's colors, with its six hues.
struct ThemePreview: View {
    let colors: ThemeColors
    /// Off for your Ghostty colors, which are only a background and a foreground, so none are made up.
    let hues: Bool

    var body: some View {
        let t = colors
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text("~/farol ").foregroundStyle(t.ansi[4])
                Text("❯ ").foregroundStyle(t.ansi[2])
                Text("ls").foregroundStyle(t.foreground)
            }
            HStack(spacing: 8) {
                Text("src").foregroundStyle(t.ansi[4])
                Text("build.sh").foregroundStyle(t.ansi[2])
                Text("TODO").foregroundStyle(t.ansi[1])
            }
            HStack(spacing: 0) {
                Text("❯ ").foregroundStyle(t.ansi[2])
                Rectangle().fill(t.cursor).frame(width: 6, height: 11)
                Spacer(minLength: 8)
                // The six hues side by side, since the sample above shows only three and many dark themes look alike by it.
                if hues {
                    HStack(spacing: 3) {
                        ForEach(1..<7, id: \.self) { i in
                            Circle().fill(t.ansi[i]).frame(width: 8, height: 8)
                        }
                    }
                }
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
        .background(t.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

extension Color {
    init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# \""))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
