import AppKit
import SwiftUI

/// Farol's own tooltip: a small label under the hovered control, in the theme's colors.
/// macOS tooltips never became visible in Farol's window, so this draws one itself in a borderless child window.
/// That window floats above the panels, so a tip under the narrow title bar isn't clipped.
final class HoverTip {
    static let shared = HoverTip()

    /// Set from the terminal theme, like the rest of the window.
    var colors = (background: NSColor.black, foreground: NSColor.white) { didSet { restyle() } }

    private static let delay: TimeInterval = 0.5
    /// Moving from one control to the next within this long shows the next tip at once, as macOS does.
    private static let warmth: TimeInterval = 0.5
    private var leftAt: Date?
    private let panel: NSPanel
    private let bubble = Bubble()
    private var pending: DispatchWorkItem?
    private weak var owner: NSWindow?
    private var clickMonitor: Any?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView = bubble
        restyle()
        // A click means the tip did its job, and the control may move or change under it.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            self?.hide()
            return event
        }
    }

    /// Shows `text` under `rect`, a rect in screen coordinates, after a short pause. "Name (⌘K)" shows the shortcut muted.
    func show(_ text: String, below rect: NSRect, in window: NSWindow) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in guard let self else { return }; present(styled(text), below: rect, in: window, leading: false) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// A larger tip with its own styling, starting at the left of `rect` so it reads from where the mouse is.
    func show(card: NSAttributedString, below rect: NSRect, in window: NSWindow) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.present(card, below: rect, in: window, leading: true) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private var wait: TimeInterval {
        guard let leftAt, Date().timeIntervalSince(leftAt) < Self.warmth else { return Self.delay }
        return 0
    }

    /// `leaving` is the mouse moving off a control whose tip showed, which keeps the next one quick. A click or a key resets that.
    func hide(leaving: Bool = false) {
        pending?.cancel()
        pending = nil
        leftAt = leaving && panel.isVisible ? Date() : nil
        guard panel.isVisible else { return }
        owner?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func present(_ text: NSAttributedString, below rect: NSRect, in window: NSWindow, leading: Bool) {
        guard NSApp.isActive, window.isVisible else { return }
        bubble.text = text
        let size = bubble.text.size()
        let width = ceil(size.width) + 2 * Bubble.padding.width, height = ceil(size.height) + 2 * Bubble.padding.height
        var origin = NSPoint(x: leading ? rect.minX : rect.midX - width / 2, y: rect.minY - 6 - height)
        // Stays on screen when the control sits near an edge.
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - width - 4)
            if origin.y < screen.minY { origin.y = rect.maxY + 6 }
        }
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        // Fades in and settles a few points away from the control, so it arrives rather than blinks on.
        let still = !Motion.enabled
        panel.setFrame(still ? frame : frame.offsetBy(dx: 0, dy: frame.minY < rect.minY ? 3 : -3), display: true)
        panel.alphaValue = 0
        if owner !== window {
            owner?.removeChildWindow(panel)
            owner = window
        }
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func styled(_ text: String) -> NSAttributedString {
        let name: String, shortcut: String?
        if text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) {
            name = String(text[..<open.lowerBound])
            shortcut = String(text[open.upperBound...].dropLast())
        } else {
            name = text
            shortcut = nil
        }
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let result = NSMutableAttributedString(string: name, attributes: [.font: font, .foregroundColor: colors.foreground])
        if let shortcut {
            result.append(NSAttributedString(string: "   " + shortcut, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: colors.background.mixed(with: colors.foreground, 0.5),
            ]))
        }
        return result
    }

    private func restyle() {
        bubble.fill = colors.background.mixed(with: colors.foreground, 0.12)
        bubble.edge = colors.background.mixed(with: colors.foreground, 0.16)
        bubble.needsDisplay = true
    }
}

/// The tip's rounded background and its text, drawn directly so every part of the text shows.
private final class Bubble: NSView {
    static let padding = NSSize(width: 9, height: 5)

    var text = NSAttributedString() { didSet { needsDisplay = true } }
    var fill = NSColor.darkGray
    var edge = NSColor.gray

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        fill.setFill()
        shape.fill()
        edge.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        text.draw(at: NSPoint(x: Self.padding.width, y: Self.padding.height))
    }
}

extension View {
    /// Farol's tooltip, see HoverTip. Clicks pass through to the view as before.
    func hoverTip(_ text: String) -> some View {
        overlay(HoverTipAnchor(text: text))
    }
}

/// An invisible view over the control that watches the mouse and places the tip under it.
private struct HoverTipAnchor: NSViewRepresentable {
    let text: String

    final class Anchor: NSView {
        var text = ""
        private var area: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let new = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(new)
            area = new
        }

        override func mouseEntered(with event: NSEvent) {
            guard let window, !text.isEmpty else { return }
            HoverTip.shared.show(text, below: window.convertToScreen(convert(bounds, to: nil)), in: window)
        }

        override func mouseExited(with event: NSEvent) { HoverTip.shared.hide(leaving: true) }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { HoverTip.shared.hide() }
            super.viewWillMove(toWindow: newWindow)
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) { view.text = text }
}
