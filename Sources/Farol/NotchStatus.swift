import AppKit
import SwiftUI

/// A small black panel with agent status, shown while an agent is active. Hovering it shows the sessions.
/// At the notch it grows the notch like the Dynamic Island.
/// On the screen edge it's a slim tab on the right, which no other app competes for and which works on any Mac.
final class NotchStatus {
    enum Place: String, CaseIterable {
        case notch, edge
    }

    var onSelect: ((Session) -> Void)?
    var place = Place.notch {
        didSet {
            model.place = place
            refresh()
        }
    }

    private let store: SessionStore
    private let model = NotchModel()
    private var panel: NSPanel?
    private var visible = false
    private var screenObserver: Any?
    /// Where the panel is heading, which can differ from its frame while it animates.
    private var target = NSRect.zero
    private var hoverTimer: Timer?

    /// How far the notch grows on each side.
    fileprivate static let wing: CGFloat = 36
    private static let rowHeight: CGFloat = 26

    /// A Mac with a notch, so Settings only offers the option there.
    static var isAvailable: Bool { notchScreen != nil }

    private static var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
    }

    init(store: SessionStore, palette: Palette) {
        self.store = store
        model.palette = palette
        model.onSelect = { [weak self] id in
            guard let self, let session = self.store.sessions.first(where: { $0.id == id }) else { return }
            self.model.expanded = false
            NSApp.activate(ignoringOtherApps: true)
            self.onSelect?(session)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.layout(animated: false) }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        hoverTimer?.invalidate()
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        refresh()
    }

    func apply(_ palette: Palette) {
        model.palette = palette
    }

    /// Called whenever a session's activity changes.
    func refresh() {
        model.rows = store.ordered.map { NotchModel.Row(id: $0.id, name: $0.displayName, activity: $0.activity) }
        layout(animated: true)
    }

    // MARK: Window

    private func layout(animated: Bool) {
        guard visible, model.isActive || model.expanded, let frame = place == .notch ? notchFrame() : edgeFrame() else {
            panel?.orderOut(nil)
            watchHover(false)
            return
        }
        target = frame

        let panel = self.panel ?? makePanel()
        if panel.isVisible, animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()
        watchHover(true)
    }

    // MARK: Hover

    /// SwiftUI's hover flickers in a window that resizes under the mouse: it opened, closed and opened again.
    /// Checking the mouse against the target frame is stable, since once open the target is the big frame.
    /// It only runs while the panel is on screen.
    private func watchHover(_ on: Bool) {
        if !on {
            hoverTimer?.invalidate()
            hoverTimer = nil
        } else if hoverTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkHover() }
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        }
    }

    private func checkHover() {
        let inside = target.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
        guard inside != model.expanded else { return }
        model.expanded = inside
        // Names change as programs retitle their sessions, so the list is read again each time it opens.
        refresh()
    }

    /// Centered on the notch, as wide as the notch plus a wing on each side, and deeper when open.
    private func notchFrame() -> NSRect? {
        guard let screen = Self.notchScreen, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return nil
        }
        let notchWidth = screen.frame.width - left.width - right.width
        let notchHeight = screen.safeAreaInsets.top
        model.notch = NSSize(width: notchWidth, height: notchHeight)
        let collapsedWidth = notchWidth + 2 * Self.wing
        let width = model.expanded ? max(collapsedWidth, 320) : collapsedWidth
        let height = notchHeight + (model.expanded ? CGFloat(model.rows.count) * Self.rowHeight + 12 : 0)
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    /// Against the right edge of the main screen, a little below the menu bar. It opens towards the left.
    private func edgeFrame() -> NSRect? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let tab = EdgeTab.size(dots: model.active.count)
        let list = CGFloat(model.rows.count) * Self.rowHeight + 20
        let width = model.expanded ? 300 : tab.width
        let height = model.expanded ? max(tab.height, list) : tab.height
        let top = screen.visibleFrame.maxY - 48
        return NSRect(x: screen.frame.maxX - width, y: top - height, width: width, height: height)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the menu bar, which the notch sits in, and on every space, full screen ones included.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: NotchView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

private final class NotchModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let name: String
        let activity: Session.Activity
    }

    @Published var rows: [Row] = []
    @Published var expanded = false
    @Published var palette: Palette?
    @Published var notch = NSSize(width: 180, height: 32)
    @Published var place = NotchStatus.Place.notch
    var onSelect: ((UUID) -> Void)?

    var active: [Row] { rows.filter { $0.activity != .idle } }
    var isActive: Bool { !active.isEmpty }

    /// The most urgent state across sessions, like the menu bar lamp.
    var top: Session.Activity {
        let activities = rows.map(\.activity)
        return activities.contains(.waiting) ? .waiting
            : activities.contains(.working) ? .working
            : activities.contains(.done) ? .done : .idle
    }
}

private struct NotchView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        if model.place == .edge {
            EdgeView(model: model)
        } else {
            notch
        }
    }

    private var notch: some View {
        VStack(spacing: 0) {
            header
            if model.expanded {
                VStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        NotchRow(row: row, color: color(row.activity)) { model.onSelect?(row.id) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Black like the notch, with its rounded lower corners, so the two read as one shape.
        .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
    }

    /// Farol's icon left of the notch and the active count right of it, in the state's color. The notch itself stays empty.
    private var header: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                // The variant chosen in Settings → Appearance, so it matches the Dock.
                if let icon = AppIcon.current.image {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 20, height: 20)
                }
            }
            .frame(width: NotchStatus.wing)
            Color.clear.frame(width: model.notch.width)
            Text(model.isActive ? "\(model.active.count)" : "")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(color(model.top) ?? .white)
                .frame(width: NotchStatus.wing)
            Spacer(minLength: 0)
        }
        .frame(height: model.notch.height)
    }

    private func color(_ activity: Session.Activity) -> Color? {
        model.palette?.color(activity).map(Color.init)
    }
}

/// The screen edge style: a slim tab with Farol's icon and one dot per active session.
/// Open, the session list sits to the left of the tab, so the tab itself never moves.
private struct EdgeView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if model.expanded {
                VStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        NotchRow(row: row, color: color(row.activity)) { model.onSelect?(row.id) }
                    }
                }
                .padding(.vertical, 10)
                .padding(.leading, 8)
                .frame(maxWidth: .infinity)
            }
            EdgeTab(dots: model.active.map { color($0.activity) ?? .white })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(Color.black, in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14))
    }

    private func color(_ activity: Session.Activity) -> Color? {
        model.palette?.color(activity).map(Color.init)
    }
}

private struct EdgeTab: View {
    let dots: [Color]

    /// Dots past this many would make the tab too tall, so the rest show as a count.
    static let maxDots = 6
    private static let width: CGFloat = 38

    static func size(dots: Int) -> CGSize {
        let shown = min(dots, maxDots)
        let extra: CGFloat = dots > maxDots ? 16 : 0
        return CGSize(width: width, height: 14 + 22 + 10 + CGFloat(shown) * 15 + extra + 8)
    }

    var body: some View {
        VStack(spacing: 7) {
            if let icon = AppIcon.current.image {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 22, height: 22)
            }
            Spacer().frame(height: 3)
            ForEach(Array(dots.prefix(Self.maxDots).enumerated()), id: \.offset) { _, color in
                Circle().fill(color).frame(width: 8, height: 8)
            }
            if dots.count > Self.maxDots {
                Text("+\(dots.count - Self.maxDots)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.top, 14)
        .frame(width: Self.width)
    }
}

private struct NotchRow: View {
    let row: NotchModel.Row
    let color: Color?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color ?? .clear)
                .overlay(Circle().strokeBorder(Color.white.opacity(color == nil ? 0.35 : 0), lineWidth: 1.2))
                .frame(width: 7, height: 7)
            Text(row.name).font(.system(size: 12.5)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 8)
            Text(state).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onClickableHover { hovering = $0 }
    }

    private var state: String {
        switch row.activity {
        case .working: "Working"
        case .waiting: "Waiting for you"
        case .done: "Done"
        case .idle: ""
        }
    }
}
