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
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?
    private weak var owner: NSWindow?
    private var clickMonitor: Any?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 5
        content.layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 11.5)
        content.addSubview(label)
        panel.contentView = content
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
        let work = DispatchWorkItem { [weak self] in self?.present(text, below: rect, in: window) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    func hide() {
        pending?.cancel()
        pending = nil
        guard panel.isVisible else { return }
        owner?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func present(_ text: String, below rect: NSRect, in window: NSWindow) {
        guard NSApp.isActive, window.isVisible else { return }
        label.attributedStringValue = styled(text)
        let size = label.attributedStringValue.size()
        let width = ceil(size.width) + 16, height = ceil(size.height) + 8
        label.frame = NSRect(x: 8, y: 4, width: ceil(size.width) + 2, height: ceil(size.height))
        var origin = NSPoint(x: rect.midX - width / 2, y: rect.minY - 6 - height)
        // Stays on screen when the control sits near an edge.
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - width - 4)
            if origin.y < screen.minY { origin.y = rect.maxY + 6 }
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        if owner !== window {
            owner?.removeChildWindow(panel)
            owner = window
        }
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
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
        let font = NSFont.systemFont(ofSize: 11.5)
        let result = NSMutableAttributedString(string: name, attributes: [.font: font, .foregroundColor: colors.foreground])
        if let shortcut {
            result.append(NSAttributedString(string: "  " + shortcut, attributes: [
                .font: font, .foregroundColor: colors.background.mixed(with: colors.foreground, 0.55),
            ]))
        }
        return result
    }

    private func restyle() {
        panel.contentView?.layer?.backgroundColor = colors.background.mixed(with: colors.foreground, 0.1).cgColor
        panel.contentView?.layer?.borderColor = colors.background.mixed(with: colors.foreground, 0.2).cgColor
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

        override func mouseExited(with event: NSEvent) { HoverTip.shared.hide() }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { HoverTip.shared.hide() }
            super.viewWillMove(toWindow: newWindow)
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) { view.text = text }
}
