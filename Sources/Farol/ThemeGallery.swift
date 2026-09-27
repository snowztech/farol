import SwiftUI
import GhosttyTerminal

/// The colors a preview card needs, read straight from a Ghostty theme file.
struct ThemeColors {
    let background: Color
    let foreground: Color
    let cursor: Color
    let ansi: [Color]

    /// Ghostty's default ANSI colors, for themes that leave some out.
    private static let defaultANSI = ["1d1f21", "cc6666", "b5bd68", "f0c674", "81a2be", "b294bb", "8abeb7", "c5c8c6"]
        .map { Color(hex: $0)! }

    /// Preview for "no Farol theme": whatever the user's Ghostty config sets.
    init(background: NSColor, foreground: NSColor) {
        self.background = Color(nsColor: background)
        self.foreground = Color(nsColor: foreground)
        cursor = self.foreground
        ansi = Self.defaultANSI
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
        let colors = ThemeColors(
            background: bg,
            foreground: fg,
            cursor: values["cursor-color"].flatMap(Color.init(hex:)) ?? fg,
            ansi: (0..<8).map { palette[$0] ?? defaultANSI[$0] })
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

    /// Your own themes first, then Ghostty's. Yours are set by full path, since Ghostty only looks for names in its own folders.
    static func all() -> [Theme] {
        let user = ((try? FileManager.default.contentsOfDirectory(atPath: userDirectory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { name -> Theme in
                let url = userDirectory.appendingPathComponent(name)
                return Theme(name: name, value: url.path, url: url)
            }
        let bundled = TerminalRuntime.bundledThemes.map {
            Theme(name: $0, value: $0, url: TerminalRuntime.themesDirectory?.appendingPathComponent($0))
        }
        return [Theme(name: "Default", value: "", url: nil)] + user + bundled
    }
}

struct ThemeGallery: View {
    let query: String
    @Binding var selected: String
    let ghosttyConfig: ThemeColors
    let palette: Palette

    let themes: [Theme]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: 14)], spacing: 18) {
            ForEach(filtered, id: \.self) { theme in
                ThemeCard(name: theme.name, colors: theme.url.map(ThemeColors.load) ?? ghosttyConfig,
                          selected: theme.value == selected, palette: palette)
                    .onTapGesture { selected = theme.value }
            }
        }
    }

    private var filtered: [Theme] {
        query.isEmpty ? themes : themes.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

private struct ThemeCard: View {
    let name: String
    let colors: ThemeColors
    let selected: Bool
    let palette: Palette

    @State private var hovering = false

    var body: some View {
        let t = colors
        VStack(alignment: .leading, spacing: 7) {
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
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
            .background(t.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? palette.accent : hovering ? palette.muted : palette.line,
                                  lineWidth: selected ? 2 : 1))

            Text(name)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? palette.text : palette.muted)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

extension Color {
    init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# \""))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
