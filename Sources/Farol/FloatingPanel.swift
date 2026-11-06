import AppKit
import SwiftUI

/// Farol's own small floating panel, for lists you pick from and fields you type into, like the definitions list and Go to Line.
/// Rounded, bordered and on the theme's background, as the ⌘P switcher is. It closes on Escape, a click elsewhere, or when the content says.
@MainActor
enum FloatingPanel {
    /// `place` gets the content's size and the screen's visible frame and says where its bottom left goes, in screen points.
    /// It is then kept on screen. `content` gets a way to close the panel. `dismissed` runs however it closes.
    static func show<Content: View>(palette: Palette, over window: NSWindow, place: (NSSize, NSRect) -> NSPoint,
                                    dismissed: (() -> Void)? = nil,
                                    @ViewBuilder content: (@escaping () -> Void) -> Content) {
        Panel.current?.dismiss()
        let panel = Panel()
        panel.dismissed = dismissed
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let hosting = FittingHost(rootView: content { [weak panel] in panel?.dismiss() }
            .background(palette.boxed ? palette.surface : palette.background)
            .clipShape(shape)
            .overlay(shape.strokeBorder(palette.line))
            .modifier(GrowIn())
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

    /// Closes the one open, if any.
    static func dismiss() { Panel.current?.dismiss() }
}

/// Opens from a touch smaller at its top edge, the way a menu drops, so it reads as coming from above rather than appearing.
private struct GrowIn: ViewModifier {
    @State private var shown = !Motion.enabled

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.97, anchor: .top)
            .onAppear { withAnimation(.easeOut(duration: 0.12)) { shown = true } }
    }
}

/// Follows its content's height with its top edge held, so a list that fills in after opening, or narrows as you type, grows down from where it opened.
private final class FittingHost<Content: View>: NSHostingView<Content> {
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard let window else { return }
        let height = fittingSize.height
        guard height != window.frame.height else { return }
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        window.setFrame(frame, display: true)
    }
}

/// A borderless panel that takes the keyboard for its list, and goes away on a click anywhere else or when another window takes over.
private final class Panel: NSPanel {
    /// Held here, since nothing else keeps a borderless panel alive once it is shown.
    static var current: Panel?
    var dismissed: (() -> Void)?
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
        dismissed?()
    }
}
