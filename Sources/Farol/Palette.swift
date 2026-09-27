import AppKit
import SwiftUI

/// Every chrome color comes from the terminal theme, so Farol looks right with any of them.
/// Farol is monochrome: marks use the text color, and motion, not hue, is what calls for attention.
struct Palette: Equatable {
    let background: Color
    let surface: Color
    let raised: Color
    let line: Color
    let text: Color
    let muted: Color
    /// Selected marks and the agent dot.
    let accent: Color
    /// Tint for macOS switches and pickers. A mid gray, since white on a switch would hide its white knob.
    let control: Color
    let isDark: Bool

    init(background bg: NSColor, foreground fg: NSColor) {
        isDark = bg.isDark
        background = Color(nsColor: bg)
        surface = Color(nsColor: bg.mixed(with: fg, 0.035))
        raised = Color(nsColor: bg.mixed(with: fg, 0.085))
        line = Color(nsColor: bg.mixed(with: fg, 0.11))
        text = Color(nsColor: fg)
        muted = Color(nsColor: bg.mixed(with: fg, 0.55))
        accent = Color(nsColor: fg)
        control = Color(nsColor: bg.mixed(with: fg, 0.42))
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
