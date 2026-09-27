import AppKit
import SwiftUI

/// Every chrome color comes from the terminal theme, so Farol looks right with any of them.
struct Palette: Equatable {
    let background: Color
    let surface: Color
    let raised: Color
    let line: Color
    let text: Color
    let muted: Color
    let accent: Color
    let isDark: Bool

    init(background bg: NSColor, foreground fg: NSColor, accent: NSColor) {
        isDark = bg.isDark
        background = Color(nsColor: bg)
        surface = Color(nsColor: bg.mixed(with: fg, 0.035))
        raised = Color(nsColor: bg.mixed(with: fg, 0.085))
        line = Color(nsColor: bg.mixed(with: fg, 0.11))
        text = Color(nsColor: fg)
        muted = Color(nsColor: bg.mixed(with: fg, 0.55))
        // Some themes use blue as the background itself. Fall back to the text color there.
        self.accent = Color(nsColor: accent.contrast(with: bg) >= 2.5 ? accent : fg)
    }
}

extension NSColor {
    var isDark: Bool {
        guard let c = usingColorSpace(.sRGB) else { return true }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.5
    }

    /// WCAG contrast ratio, 1 (none) to 21 (black on white).
    func contrast(with other: NSColor) -> CGFloat {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        func channel(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    func mixed(with other: NSColor, _ amount: CGFloat) -> NSColor {
        blended(withFraction: amount, of: other) ?? self
    }
}
