import AppKit
import SwiftUI

/// Farol's own small floating panel, for lists you pick from and fields you type into, like the definitions list and Go to Line.
/// Rounded, bordered and on the theme's background, as the ⌘P switcher is. It closes on Escape, a click elsewhere, or when the content says.
@MainActor
enum FloatingPanel {
    /// `place` gets the content's size and the screen's visible frame and says where its bottom left goes, in screen points.
    /// It is then kept on screen. `content` gets a way to close the panel.
    static func show<Content: View>(palette: Palette, over window: NSWindow, place: (NSSize, NSRect) -> NSPoint,
                                    @ViewBuilder content: (@escaping () -> Void) -> Content) {
        Panel.current?.dismiss()
        let panel = Panel()
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let hosting = NSHostingView(rootView: content { [weak panel] in panel?.dismiss() }
            .background(palette.boxed ? palette.surface : palette.background)
            .clipShape(shape)
            .overlay(shape.strokeBorder(palette.line))
            .onExitCommand { [weak panel] in panel?.dismiss() })
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var origin = place(size, screen)
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.present(over: window)
    }
}

/// A borderless panel that takes the keyboard for its list, and goes away on a click anywhere else or when another window takes over.
private final class Panel: NSPanel {
    /// Held here, since nothing else keeps a borderless panel alive once it is shown.
    static var current: Panel?
    private var monitor: Any?
    private var takeover: Any?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    func present(over parent: NSWindow) {
        Self.current = self
        parent.addChildWindow(self, ordered: .above)
        if Motion.enabled {
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
        }
        makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if event.window !== self { self?.dismiss() }
            return event
        }
        // Another window taking the keyboard, like ⌘P's list or a sheet, closes it too, even without a click.
        takeover = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
            [weak self] note in
            if note.object as? NSWindow !== self { MainActor.assumeIsolated { self?.dismiss() } }
        }
    }

    /// Only once another window really has the keyboard, since taking it can bounce once while the panel comes up.
    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in
            if let self, !isKeyWindow { dismiss() }
        }
    }

    func dismiss() {
        guard isVisible else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let takeover { NotificationCenter.default.removeObserver(takeover) }
        takeover = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
        if Self.current === self { Self.current = nil }
    }
}
