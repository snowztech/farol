import AppKit

/// The small icon button of the AppKit parts, drawn like IconButton and CloseButton in SwiftUI:
/// a muted symbol that lights up on a soft rounded background under the mouse.
final class QuietButton: NSButton {
    private let run: () -> Void
    private var colors = (muted: NSColor.secondaryLabelColor, hover: NSColor.labelColor, background: NSColor.clear)
    private var hovering = false { didSet { refresh() } }

    init(symbol: String, help: String, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        imagePosition = .imageOnly
        isBordered = false
        toolTip = help
        target = self
        self.action = #selector(fire)
        wantsLayer = true
        layer?.cornerRadius = 5
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(background: NSColor, foreground: NSColor) {
        colors = (background.mixed(with: foreground, 0.55), foreground, background.mixed(with: foreground, 0.1))
        refresh()
    }

    private func refresh() {
        contentTintColor = hovering ? colors.hover : colors.muted
        layer?.backgroundColor = hovering ? colors.background.cgColor : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    @objc private func fire() { run() }
}
