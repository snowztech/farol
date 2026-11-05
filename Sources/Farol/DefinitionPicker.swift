import AppKit
import FarolCore
import SwiftUI

/// The places a ⌘-clicked name is declared, when there are several. Rows shaped like the session switcher's, so it reads as Farol's.
struct DefinitionPicker: View {
    let word: String
    let matches: [FileSearch.Match]
    let palette: Palette
    let choose: (FileSearch.Match) -> Void

    /// Under the arrows or the mouse. Return opens it.
    @State private var active = 0
    @FocusState private var focused: Bool

    private static let rowHeight: CGFloat = 30

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            Text("\(matches.count) definitions of \(Text(word).font(.system(size: 11, design: .monospaced)).foregroundColor(p.text))")
                .font(.system(size: 11))
                .foregroundStyle(p.muted)
                .padding(.horizontal, 15)
                .padding(.top, 10)
                .padding(.bottom, 2)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                            row(match, lit: index == active, palette: p)
                                .onClickableHover { if $0 { active = index } }
                                .id(index)
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(CGFloat(matches.count) * (Self.rowHeight + 1) + 12, 320))
                .onChange(of: active) { _, row in scroll.scrollTo(row) }
            }
        }
        .frame(width: 480)
        .foregroundStyle(p.text)
        .background(p.boxed ? p.surface : p.background)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.return) {
            choose(matches[active])
            return .handled
        }
        .onAppear { focused = true }
    }

    private func row(_ match: FileSearch.Match, lit: Bool, palette p: Palette) -> some View {
        Button { choose(match) } label: {
            HStack(spacing: 9) {
                FileIcon(path: match.path).font(.system(size: 11)).foregroundStyle(p.muted).frame(width: 15)
                Text(match.text)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                Text("\((match.path as NSString).lastPathComponent):\(match.line)")
                    .font(.system(size: 11))
                    .foregroundStyle(p.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 9)
            .frame(height: Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lit ? p.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietPress())
        .help("\(match.path):\(match.line)")
    }

    private func move(_ step: Int) -> KeyPress.Result {
        active = (active + step + matches.count) % matches.count
        return .handled
    }

    /// Opens under the name that was clicked, or above it near the bottom of the screen.
    /// A panel of its own rather than a popover, whose arrow is drawn by macOS in its own colors and whose anchor drifts inside a scroll view.
    @MainActor
    static func show(_ matches: [FileSearch.Match], of word: String, palette: Palette, below rect: NSRect, in view: NSView,
                     choose: @escaping (FileSearch.Match) -> Void) {
        guard let window = view.window else { return }
        PickerPanel.current?.dismiss()
        let panel = PickerPanel()
        let picker = DefinitionPicker(word: word, matches: matches, palette: palette) { [weak panel] match in
            panel?.dismiss()
            choose(match)
        }
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let hosting = NSHostingView(rootView: picker
            .clipShape(shape)
            .overlay(shape.strokeBorder(palette.line))
            .onExitCommand { [weak panel] in panel?.dismiss() })
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        let anchor = window.convertToScreen(view.convert(rect, to: nil))
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var origin = NSPoint(x: anchor.minX - 15, y: anchor.minY - 4 - size.height)
        if origin.y < screen.minY { origin.y = anchor.maxY + 4 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.present(over: window)
    }
}

/// A borderless panel that takes the keyboard for its list, and goes away on a click anywhere else or when another window takes over.
private final class PickerPanel: NSPanel {
    /// Held here, since nothing else keeps a borderless panel alive once it is shown.
    static var current: PickerPanel?
    private var monitor: Any?

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
        parent?.removeChildWindow(self)
        orderOut(nil)
        if Self.current === self { Self.current = nil }
    }
}
