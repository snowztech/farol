import AppKit
import FarolCore
import SwiftUI

/// A small black panel with agent status, shown while an agent is active. Hovering it shows the sessions.
/// At the notch it grows the notch like the Dynamic Island.
/// On the screen edge it's a slim tab on the right, which no other app competes for and which works on any Mac.
final class NotchStatus {
    enum Place: String, CaseIterable {
        case notch, edge
    }

    var onSelect: ((Session) -> Void)?
    /// What was picked on a question shown here.
    var onAnswer: ((Session, [String: String]) -> Void)?
    var onChat: ((Session) -> Void)?
    var onTerminal: ((Session) -> Void)?
    var place = Place.notch {
        didSet {
            model.place = place
            refresh()
        }
    }

    private let store: SessionStore
    private let model = NotchModel()
    private var panel: QuestionPanel?
    private var visible = false
    private var screenObserver: Any?
    /// Where the panel is heading, which can differ from its frame while it animates.
    private var target = NSRect.zero
    private var hoverTimer: Timer?
    /// Watching for a click away from the question while it shows, in other apps and in Farol's own windows.
    private var clickMonitors: [Any] = []
    /// A question closed by clicking away stays pending, but isn't put back on the panel.
    private var dismissedAsk: UUID?
    /// Where the mouse grabbed the tab, relative to the panel's origin, while it's being dragged.
    private var grab: NSPoint?
    private static let edgeLeftKey = "agents.edgeLeft"
    private static let edgeFromTopKey = "agents.edgeFromTop"

    /// How far the notch grows on each side.
    fileprivate static let wing: CGFloat = 36
    private static let rowHeight: CGFloat = 26
    /// A question needs room for its options, and the edge tab sits beside it.
    fileprivate static let questionWidth: CGFloat = 440

    /// A Mac with a notch, so Settings only offers the option there.
    static var isAvailable: Bool { notchScreen != nil }

    private static var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
    }

    init(store: SessionStore, palette: Palette) {
        self.store = store
        model.palette = palette
        model.edgeLeft = UserDefaults.standard.bool(forKey: Self.edgeLeftKey)
        model.onDrag = { [weak self] ended in self?.drag(ended: ended) }
        model.onSelect = { [weak self] id in
            guard let self, let session = self.store.sessions.first(where: { $0.id == id }) else { return }
            self.model.expanded = false
            NSApp.activate(ignoringOtherApps: true)
            self.onSelect?(session)
        }
        model.onCardHeight = { [weak self] in self?.layout(animated: true) }
        model.onAnswer = { [weak self] id, answers in self?.session(id).map { self?.onAnswer?($0, answers) } }
        model.onChat = { [weak self] id in self?.session(id).map { self?.onChat?($0) } }
        model.onTerminal = { [weak self] id in self?.session(id).map { self?.onTerminal?($0) } }
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

    private func session(_ id: UUID) -> Session? { store.sessions.first { $0.id == id } }

    /// Called whenever a session's activity changes, or a question comes or goes.
    func refresh() {
        model.rows = store.ordered.map { NotchModel.Row(id: $0.id, name: $0.displayName, activity: $0.activity) }
        // A question shows here unless the window is already asking it, in a sheet over the session you are in.
        let asking = store.ordered.filter { $0.ask != nil && $0.ask?.id != dismissedAsk && !(NSApp.isActive && $0.id == store.selectedID) }
        let question = asking.first.flatMap { session in
            session.ask.map {
                NotchModel.Question(id: $0.id, session: session.id, name: session.displayName, questions: $0.questions, more: asking.count - 1)
            }
        }
        if model.question != question {
            model.question = question
            model.cardHeight = 0
        }
        watchClicks(question != nil)
        layout(animated: true)
    }

    /// A click anywhere but on the panel closes the question. It is still there to answer from its notification or its session.
    private func watchClicks(_ on: Bool) {
        guard on != !clickMonitors.isEmpty else { return }
        guard on else {
            clickMonitors.forEach(NSEvent.removeMonitor)
            clickMonitors = []
            return
        }
        let buttons: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let close = { [weak self] in
            guard let self, let id = self.model.question?.id else { return }
            self.dismissedAsk = id
            self.refresh()
        }
        // Other apps get their clicks first, and this only hears about them.
        if let other = NSEvent.addGlobalMonitorForEvents(matching: buttons, handler: { _ in close() }) { clickMonitors.append(other) }
        // Farol's own windows, where the click still goes through to what was clicked.
        if let own = NSEvent.addLocalMonitorForEvents(matching: buttons, handler: { [weak self] event in
            if event.window !== self?.panel { close() }
            return event
        }) { clickMonitors.append(own) }
    }

    // MARK: Window

    private func layout(animated: Bool) {
        guard visible, model.isActive || model.expanded || model.question != nil, let frame = place == .notch ? notchFrame() : edgeFrame() else {
            panel?.orderOut(nil)
            watchHover(false)
            return
        }
        target = frame

        let panel = self.panel ?? makePanel()
        // The keyboard is only taken for a question, to type an answer. A status panel never has it.
        panel.takesKey = model.question != nil
        // Still key after the question is gone, it would keep what you type. Ordering it out hands the keyboard back.
        if !panel.takesKey, panel.isKeyWindow { panel.orderOut(nil) }
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
        guard grab == nil else { return }
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
        let width = model.question != nil ? max(collapsedWidth, Self.questionWidth)
            : model.expanded ? max(collapsedWidth, 320) : collapsedWidth
        let body = model.question != nil ? model.questionHeight : model.expanded ? CGFloat(model.rows.count) * Self.rowHeight + 12 : 0
        let height = notchHeight + body
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    /// Against the left or right edge of the main screen, at the height it was dragged to. It opens away from the edge.
    private func edgeFrame() -> NSRect? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let tab = EdgeTab.size(dots: model.active.count)
        let list = CGFloat(model.rows.count) * Self.rowHeight + 20
        let width = model.question != nil ? Self.questionWidth + tab.width : model.expanded ? 300 : tab.width
        let height = model.question != nil ? max(tab.height, model.questionHeight) : model.expanded ? max(tab.height, list) : tab.height
        let visible = screen.visibleFrame
        let saved = UserDefaults.standard.object(forKey: Self.edgeFromTopKey) as? Double ?? 48
        // Kept on screen, however the saved height compares with this screen and this many rows.
        let top = min(max(visible.maxY - CGFloat(saved), visible.minY + height), visible.maxY)
        let x = model.edgeLeft ? screen.frame.minX : screen.frame.maxX - width
        return NSRect(x: x, y: top - height, width: width, height: height)
    }

    /// Follows the mouse while the tab is dragged, then snaps to the nearer side and keeps the height for next time.
    private func drag(ended: Bool) {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let mouse = NSEvent.mouseLocation
        if grab == nil {
            model.expanded = false
            grab = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
        }
        guard let grab else { return }
        if !ended {
            panel.setFrameOrigin(NSPoint(x: mouse.x - grab.x, y: mouse.y - grab.y))
            return
        }
        self.grab = nil
        model.edgeLeft = panel.frame.midX < screen.frame.midX
        UserDefaults.standard.set(model.edgeLeft, forKey: Self.edgeLeftKey)
        UserDefaults.standard.set(Double(screen.visibleFrame.maxY - panel.frame.maxY), forKey: Self.edgeFromTopKey)
        layout(animated: true)
    }

    private func makePanel() -> QuestionPanel {
        let panel = QuestionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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

/// The status panel, which can take the keyboard while a question is open.
private final class QuestionPanel: NSPanel {
    var takesKey = false
    override var canBecomeKey: Bool { takesKey }

    override func sendEvent(_ event: NSEvent) {
        // The first click on a window that isn't key only makes it key, and the button under it would miss it.
        if event.type == .leftMouseDown, takesKey, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
}

private final class NotchModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let name: String
        let activity: Session.Activity
    }

    /// What an agent asks, with the session that asks it.
    struct Question: Equatable {
        let id: UUID
        let session: UUID
        let name: String
        let questions: [AgentQuestion]
        /// Other sessions waiting on a question of their own.
        let more: Int
    }

    @Published var rows: [Row] = []
    @Published var question: Question?
    /// How tall the question is once drawn, which the panel is sized to. Zero until it has been.
    var cardHeight: CGFloat = 0
    var questionHeight: CGFloat { cardHeight == 0 ? 220 : cardHeight }
    var onCardHeight: (() -> Void)?
    var onAnswer: ((UUID, [String: String]) -> Void)?
    var onChat: ((UUID) -> Void)?
    var onTerminal: ((UUID) -> Void)?
    @Published var expanded = false
    @Published var palette: Palette?
    @Published var notch = NSSize(width: 180, height: 32)
    @Published var place = NotchStatus.Place.notch
    /// The edge tab sits on the left side, after being dragged there.
    @Published var edgeLeft = false
    var onSelect: ((UUID) -> Void)?
    /// Called as the edge tab is dragged, with true when the drag ends.
    var onDrag: ((Bool) -> Void)?

    var active: [Row] { rows.filter { $0.activity != .idle } }
    var isActive: Bool { !active.isEmpty }

    /// The most urgent state across sessions, like the menu bar lamp.
    var top: Session.Activity {
        let activities = rows.map(\.activity)
        return activities.contains(.stopped) ? .stopped
            : activities.contains(.waiting) ? .waiting
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
            if let question = model.question {
                QuestionCard(model: model, question: question)
            } else if model.expanded {
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

/// The question an agent asks, with its options as buttons, on the black panel.
private struct QuestionCard: View {
    @ObservedObject var model: NotchModel
    let question: NotchModel.Question

    var body: some View {
        QuestionForm(
            questions: question.questions, colors: .notch,
            asker: question.name + (question.more > 0 ? ", \(question.more) more waiting" : ""), maxHeight: 360,
            answer: { model.onAnswer?(question.session, $0) },
            chat: { model.onChat?(question.session) },
            useTerminal: { model.onTerminal?(question.session) })
            .id(question.id)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { Color.clear.preference(key: CardHeightKey.self, value: $0.size.height) })
            .onPreferenceChange(CardHeightKey.self) { height in
                guard height > 0, height != model.cardHeight else { return }
                model.cardHeight = height
                model.onCardHeight?()
            }
    }
}

/// Apart from the form's own height key, which its inner scroll view reports, so the two don't mix.
private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The screen edge style: a slim tab with Farol's icon and one dot per active session.
/// Open, the session list sits to the left of the tab, so the tab itself never moves.
private struct EdgeView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let left = model.edgeLeft
        HStack(alignment: .top, spacing: 0) {
            if left { tab }
            if let question = model.question {
                QuestionCard(model: model, question: question)
            } else if model.expanded {
                VStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        NotchRow(row: row, color: color(row.activity)) { model.onSelect?(row.id) }
                    }
                }
                .padding(.vertical, 10)
                .padding(left ? .trailing : .leading, 8)
                .frame(maxWidth: .infinity)
            }
            if !left { tab }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: left ? .topLeading : .topTrailing)
        // Rounded on the side away from the screen edge, square against it.
        .background(Color.black, in: UnevenRoundedRectangle(
            topLeadingRadius: left ? 0 : 14, bottomLeadingRadius: left ? 0 : 14,
            bottomTrailingRadius: left ? 14 : 0, topTrailingRadius: left ? 14 : 0))
    }

    /// Dragging the tab moves the panel. The window moves under the mouse, so the drag reads the mouse on screen, not the gesture.
    private var tab: some View {
        EdgeTab(dots: model.active.map { color($0.activity) ?? .white })
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { _ in model.onDrag?(false) }
                .onEnded { _ in model.onDrag?(true) })
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
        case .stopped: "Conflicts"
        case .idle: ""
        }
    }
}
