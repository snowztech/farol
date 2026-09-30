import FarolCore
import AppKit
import GhosttyTerminal
import SwiftUI

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
    /// Git graph branches: twelve hues around the wheel, as bright and saturated as the theme's own colors.
    let lanes: [Color]
    /// Tint for macOS switches and pickers. A mid gray, since white on a switch would hide its white knob.
    let control: Color
    let code: SyntaxColors
    let diff: DiffColors
    let isDark: Bool

    init(_ runtime: TerminalRuntime) {
        self.init(background: runtime.backgroundColor, foreground: runtime.foregroundColor, ansi: runtime.ansiColors)
    }

    init(background bg: NSColor, foreground fg: NSColor, ansi: [NSColor]) {
        isDark = bg.isDark
        background = Color(nsColor: bg)
        surface = Color(nsColor: bg.mixed(with: fg, 0.035))
        raised = Color(nsColor: bg.mixed(with: fg, 0.085))
        line = Color(nsColor: bg.mixed(with: fg, 0.11))
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
        // Steps of 30 degrees, ordered so each color sits far from the one before it: blue, magenta, green, orange...
        return [7, 10, 4, 1, 6, 0, 9, 2, 5, 11, 3, 8].map {
            Color(nsColor: NSColor(hue: CGFloat($0) / 12, saturation: saturation, brightness: brightness, alpha: 1))
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
