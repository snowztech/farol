import FarolCore
import AppKit
import GhosttyTerminal
import SwiftUI

/// Settings → Appearance → Style. How the panels around the terminal are shaped and lit.
enum UIStyle: String, CaseIterable {
    /// Panels touch, with a line between them, and every highlight is a quiet gray.
    case classic
    /// Every panel is a rounded card with a gap around it, on a darker backdrop.
    case boxed
    /// Boxed, with the theme's blue tinting the panels and lighting what is selected.
    case vivid

    static let key = "appearance.style"
    static var saved: UIStyle { UserDefaults.standard.string(forKey: key).flatMap(UIStyle.init) ?? .classic }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .boxed: "Boxed"
        case .vivid: "Boxed with color"
        }
    }

    /// The space around each panel.
    var gap: CGFloat { self == .classic ? 0 : 8 }
    /// How round a panel's corners are. With the gap around it, they follow the window's own corners.
    var radius: CGFloat { self == .classic ? 0 : 10 }
}

/// Every color comes from the terminal theme, so Farol looks right with any of them.
/// The chrome is monochrome. Only agent status gets a hue, taken from the theme's own ANSI colors.
struct Palette: Equatable {
    let background: Color
    let surface: Color
    let raised: Color
    let line: Color
    let text: Color
    let muted: Color
    /// Selected marks and the agent dot.
    let accent: Color
    /// Agent status. Cyan is calm for busy, yellow asks for you, green means finished.
    let working: Color
    let waiting: Color
    let done: Color
    let added: Color
    let removed: Color
    /// A branch with commits to pull, in the theme's blue. One with commits to push uses `added`.
    let pull: Color
    /// Git graph branches: 64 colors, each far from the ones before it, as bright and saturated as the theme's own colors.
    let lanes: [Color]
    /// Tint for macOS switches and pickers. A mid gray, since white on a switch would hide its white knob.
    let control: Color
    let code: SyntaxColors
    let diff: DiffColors
    let isDark: Bool
    let style: UIStyle
    /// What shows around the panels when they are boxed. The terminal's own color otherwise.
    let backdrop: Color
    /// The selected row. Gray, or lit in the theme's blue in the style with color.
    let selection: Color

    /// A row under the mouse. Fainter than `raised`, so it never reads as selected.
    var hover: Color { raised.opacity(0.35) }

    var boxed: Bool { style != .classic }
    var vivid: Bool { style == .vivid }

    init(_ runtime: TerminalRuntime, style: UIStyle = .classic) {
        self.init(background: runtime.backgroundColor, foreground: runtime.foregroundColor, ansi: runtime.ansiColors,
                  style: style)
    }

    init(background bg: NSColor, foreground fg: NSColor, ansi: [NSColor], style: UIStyle = .classic) {
        isDark = bg.isDark
        self.style = style
        background = Color(nsColor: bg)
        // With color, the panels lean toward the theme's blue. Leaning toward the text, as the other styles do, leaves them gray.
        let blue = ansi.count > 4 ? ansi[4] : fg
        let vivid = style == .vivid
        let tint = vivid ? blue : fg
        surface = Color(nsColor: bg.mixed(with: tint, vivid ? 0.06 : 0.035))
        raised = Color(nsColor: bg.mixed(with: tint, vivid ? 0.14 : 0.085))
        line = Color(nsColor: bg.mixed(with: tint, vivid ? 0.2 : 0.11))
        selection = vivid ? Color(nsColor: bg.mixed(with: blue, 0.3)) : raised
        // Darker than the terminal in a dark theme, so the cards stand out from it. A light theme has no room above white.
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        backdrop = Color(nsColor: style == .classic ? bg : bg.isDark ? bg.mixed(with: black, 0.35) : bg.mixed(with: fg, 0.07))
        text = Color(nsColor: fg)
        muted = Color(nsColor: bg.mixed(with: fg, 0.55))
        accent = Color(nsColor: fg)
        control = Color(nsColor: bg.mixed(with: fg, 0.42))
        code = SyntaxColors(background: bg, foreground: fg, ansi: ansi)
        diff = DiffColors(background: bg, foreground: fg, added: ansi.count > 2 ? ansi[2] : fg, removed: ansi.count > 1 ? ansi[1] : fg)
        lanes = Self.lanes(matching: Array(ansi.dropFirst().prefix(6)), dark: bg.isDark)
        let ansi = { (i: Int) in Color(nsColor: ansi.count > i ? ansi[i] : fg) }
        working = ansi(6)
        waiting = ansi(3)
        done = ansi(2)
        added = ansi(2)
        removed = ansi(1)
        pull = ansi(4)
    }
}

extension Palette {
    /// A theme has six hues, too few for a busy graph, and mixing them gives muddy look-alikes.
    /// Evenly spaced hues stay apart, and the theme's average saturation and brightness keep them in its style.
    static func lanes(matching colors: [NSColor], dark: Bool) -> [Color] {
        let hsb = colors.compactMap { $0.usingColorSpace(.sRGB) }.map { ($0.saturationComponent, $0.brightnessComponent) }
        let count = CGFloat(max(hsb.count, 1))
        let saturation = max(hsb.map(\.0).reduce(0, +) / count, 0.55)
        let brightness = dark ? max(hsb.map(\.1).reduce(0, +) / count, 0.8) : min(hsb.map(\.1).reduce(0, +) / count, 0.7)
        // Each hue turns by the golden angle, so it lands in the widest gap left by the ones before and never comes back.
        // Past the first dozen the hues get close, so every dozen also changes tone: full, then softer, then deeper.
        return (0..<64).map { index in
            let hue = (7.0 / 12 + Double(index) * 0.381966).truncatingRemainder(dividingBy: 1)
            let tone = index / 12 % 3
            let s = tone == 1 ? saturation * 0.55 : saturation
            let b = tone == 2 ? brightness * (dark ? 0.78 : 0.75) : brightness
            return Color(nsColor: NSColor(hue: CGFloat(hue), saturation: s, brightness: b, alpha: 1))
        }
    }
}

/// Colors for code, from the terminal theme's ANSI palette so they always match it.
struct SyntaxColors: Equatable {
    let keyword: NSColor
    let string: NSColor
    let number: NSColor
    let comment: NSColor

    init(background: NSColor, foreground: NSColor, ansi: [NSColor]) {
        let color = { (i: Int) in ansi.count > i ? ansi[i] : foreground }
        keyword = color(5)
        string = color(2)
        number = color(3)
        comment = background.mixed(with: foreground, 0.45)
    }

    func color(_ kind: Syntax.Kind) -> NSColor {
        switch kind {
        case .keyword: keyword
        case .string: string
        case .number: number
        case .comment: comment
        }
    }
}

extension NSColor {
    var isDark: Bool {
        guard let c = usingColorSpace(.sRGB) else { return true }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.5
    }

    func mixed(with other: NSColor, _ amount: CGFloat) -> NSColor {
        blended(withFraction: amount, of: other) ?? self
    }
}
