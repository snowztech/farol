import AppKit
import SwiftUI

/// Chrome colors come from the terminal theme, so Farol looks right with any of them.
/// The accent is Farol's own: the blue of the lighthouse beam in the app icon.
struct Palette: Equatable {
    let background: Color
    let surface: Color
    let raised: Color
    let line: Color
    let text: Color
    let muted: Color
    let accent: Color
    let isDark: Bool

    static let beam = NSColor(srgbRed: 0x00 / 255, green: 0x78 / 255, blue: 0xF9 / 255, alpha: 1)

    init(background bg: NSColor, foreground fg: NSColor) {
        isDark = bg.isDark
        background = Color(nsColor: bg)
        surface = Color(nsColor: bg.mixed(with: fg, 0.035))
        raised = Color(nsColor: bg.mixed(with: fg, 0.085))
        line = Color(nsColor: bg.mixed(with: fg, 0.11))
        text = Color(nsColor: fg)
        muted = Color(nsColor: bg.mixed(with: fg, 0.55))
        // Blue backgrounds would swallow the beam, so step it toward the text color until it stands out.
        var accent = Self.beam
        for step in stride(from: 0.2, through: 0.8, by: 0.2) where accent.contrast(with: bg) < 3 {
            accent = Self.beam.mixed(with: fg, step)
        }
        self.accent = Color(nsColor: accent)
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
