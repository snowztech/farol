import AppKit

/// A short confirmation at the bottom of a pane, like "Copied". It fades out on its own.
final class PaneToast: NSView {
    private let label = NSTextField(labelWithString: "")

    init(_ text: String, background: NSColor, foreground: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.backgroundColor = background.mixed(with: foreground, 0.08).cgColor
        layer?.borderColor = background.mixed(with: foreground, 0.2).cgColor
        label.stringValue = text
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = foreground
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks go to the terminal underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var size: NSSize {
        let text = label.intrinsicContentSize
        return NSSize(width: text.width + 20, height: 22)
    }

    override func layout() {
        super.layout()
        let text = label.intrinsicContentSize
        label.frame = NSRect(x: 10, y: (bounds.height - text.height) / 2, width: text.width, height: text.height)
    }

    /// Stays about a second, then fades, or just disappears with Reduce Motion.
    func dismissLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return self.removeFromSuperview() }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self.animator().alphaValue = 0 },
                                                 completionHandler: { self.removeFromSuperview() })
        }
    }
}
