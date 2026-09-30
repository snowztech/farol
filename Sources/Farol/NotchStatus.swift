import AppKit
import SwiftUI

/// Agent status around the MacBook notch. While an agent is active, the notch grows a little on each side:
/// Farol's icon on the left, like an app in the Dynamic Island, and the number of active sessions on the right.
/// Hovering it drops down the sessions, and picking one brings Farol to it. Idle, nothing is added to the notch.
final class NotchStatus {
    var onSelect: ((Session) -> Void)?

    private let store: SessionStore
    private let model = NotchModel()
    private var panel: NSPanel?
    private var visible = false
    private var screenObserver: Any?

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
        // Names change as programs retitle their sessions, so the list is read again each time it opens.
        model.onHover = { [weak self] _ in self?.refresh() }
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
        guard visible, let screen = Self.notchScreen, let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea, model.isActive || model.expanded else {
            panel?.orderOut(nil)
            return
        }
        let notchWidth = screen.frame.width - left.width - right.width
        let notchHeight = screen.safeAreaInsets.top
        model.notch = NSSize(width: notchWidth, height: notchHeight)

        let collapsedWidth = notchWidth + 2 * Self.wing
        let width = model.expanded ? max(collapsedWidth, 320) : collapsedWidth
        let height = notchHeight + (model.expanded ? CGFloat(model.rows.count) * Self.rowHeight + 12 : 0)
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)

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
    var onHover: ((Bool) -> Void)?
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

    func hover(_ inside: Bool) {
        guard expanded != inside else { return }
        expanded = inside
        onHover?(inside)
    }
}

private struct NotchView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
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
        .onHover { model.hover($0) }
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
