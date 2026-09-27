import AppKit
import GhosttyTerminal

/// A session's terminals, split into panes. Each split holds two children and the share the first one gets.
/// Layout is plain arithmetic on that tree, which maps directly onto Ghostty's resize and equalize requests.
final class PaneContainer: NSView {
    final class Node {
        enum Axis { case horizontal, vertical }

        var terminal: TerminalView?
        var axis = Axis.horizontal
        var children: [Node] = []
        var ratio: CGFloat = 0.5
        weak var parent: Node?
        fileprivate var frame = CGRect.zero

        /// A leaf with a terminal, or an empty split node when nil.
        init(_ terminal: TerminalView?) {
            self.terminal = terminal
        }

        var leaves: [TerminalView] { terminal.map { [$0] } ?? children.flatMap(\.leaves) }
    }

    private static let divider: CGFloat = 1
    private static let unfocusedAlpha: CGFloat = 0.7

    private(set) var root: Node
    private(set) var focused: TerminalView
    private var zoomed = false
    private var dragging: Node?

    var dividerColor = NSColor.separatorColor { didSet { needsDisplay = true } }
    var onFocusChange: ((TerminalView) -> Void)?
    /// Panes were added, removed or resized, so the saved layout is out of date.
    var onLayoutChange: (() -> Void)?

    var terminals: [TerminalView] { root.leaves }

    init(_ terminal: TerminalView) {
        root = Node(terminal)
        focused = terminal
        super.init(frame: .zero)
        adopt(terminal)
    }

    /// Rebuilds saved panes. `make` creates a terminal in a folder.
    init(_ layout: PaneLayout, make: (String) -> TerminalView) {
        func build(_ layout: PaneLayout) -> Node {
            switch layout {
            case .terminal(let directory):
                return Node(make(directory))
            case .split(let horizontal, let ratio, let first, let second):
                let node = Node(nil)
                node.axis = horizontal ? .horizontal : .vertical
                node.ratio = CGFloat(ratio)
                node.children = [build(first), build(second)]
                node.children.forEach { $0.parent = node }
                return node
            }
        }
        root = build(layout)
        focused = root.leaves[0]
        super.init(frame: .zero)
        root.leaves.forEach(adopt)
    }

    var layoutSnapshot: PaneLayout {
        func snapshot(_ node: Node) -> PaneLayout {
            if let terminal = node.terminal { return .terminal(directory: terminal.workingDirectory ?? NSHomeDirectory()) }
            return .split(horizontal: node.axis == .horizontal, ratio: Double(node.ratio),
                          first: snapshot(node.children[0]), second: snapshot(node.children[1]))
        }
        return snapshot(root)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: Changes

    /// Puts `terminal` next to the focused pane, on the side `direction` points to.
    func split(_ direction: TerminalRequest.Direction, with terminal: TerminalView) {
        guard let leaf = node(of: focused) else { return }
        let old = Node(focused)
        let new = Node(terminal)
        leaf.terminal = nil
        leaf.axis = direction == .left || direction == .right ? .horizontal : .vertical
        leaf.children = direction == .left || direction == .up ? [new, old] : [old, new]
        leaf.ratio = 0.5
        leaf.children.forEach { $0.parent = leaf }
        zoomed = false
        adopt(terminal)
        focus(terminal)
        onLayoutChange?()
    }

    /// Removes a pane and lets its sibling take the space. Returns false for the last pane.
    func remove(_ terminal: TerminalView) -> Bool {
        guard let leaf = node(of: terminal), let parent = leaf.parent else { return false }
        let sibling = parent.children.first { $0 !== leaf }!
        parent.terminal = sibling.terminal
        parent.axis = sibling.axis
        parent.children = sibling.children
        parent.ratio = sibling.ratio
        parent.children.forEach { $0.parent = parent }
        terminal.removeFromSuperview()
        zoomed = false
        if terminal === focused { focus(parent.leaves[0]) }
        needsLayout = true
        onLayoutChange?()
        return true
    }

    /// Moves keyboard focus. The terminal reports back through onFocus, which records it.
    func focus(_ target: TerminalView) {
        if window?.makeFirstResponder(target) != true { noteFocused(target) }
    }

    private func noteFocused(_ target: TerminalView) {
        focused = target
        applyFocus()
        onFocusChange?(target)
    }

    func goto(_ target: TerminalRequest.SplitTarget) {
        let all = terminals
        guard all.count > 1, let index = all.firstIndex(where: { $0 === focused }) else { return }
        switch target {
        case .previous: focus(all[(index - 1 + all.count) % all.count])
        case .next: focus(all[(index + 1) % all.count])
        case .direction(let direction): neighbor(direction).map(focus)
        }
    }

    func resize(_ direction: TerminalRequest.Direction, by amount: CGFloat) {
        let axis: Node.Axis = direction == .left || direction == .right ? .horizontal : .vertical
        var node = self.node(of: focused)?.parent
        while let current = node, current.axis != axis { node = current.parent }
        guard let split = node else { return }
        let size = axis == .horizontal ? split.frame.width : split.frame.height
        guard size > 0 else { return }
        let delta = amount / size * (direction == .left || direction == .up ? -1 : 1)
        split.ratio = min(max(split.ratio + delta, 0.1), 0.9)
        needsLayout = true
        onLayoutChange?()
    }

    func equalize() {
        func reset(_ node: Node) {
            node.ratio = 0.5
            node.children.forEach(reset)
        }
        reset(root)
        needsLayout = true
        onLayoutChange?()
    }

    func toggleZoom() {
        guard terminals.count > 1 else { return }
        zoomed.toggle()
        needsLayout = true
    }

    /// Hidden sessions keep running but stop rendering.
    func setVisible(_ visible: Bool) {
        isHidden = !visible
        for terminal in terminals {
            terminal.setVisible(visible && (!zoomed || terminal === focused))
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        if zoomed, let leaf = node(of: focused) {
            terminals.forEach { $0.isHidden = $0 !== focused }
            place(leaf, in: bounds)
        } else {
            terminals.forEach { $0.isHidden = false }
            place(root, in: bounds)
        }
        applyFocus()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func place(_ node: Node, in rect: CGRect) {
        node.frame = rect
        if let terminal = node.terminal {
            terminal.frame = rect.integral
            return
        }
        let (first, second) = split(rect, node.axis, node.ratio)
        place(node.children[0], in: first)
        place(node.children[1], in: second)
    }

    private func split(_ rect: CGRect, _ axis: Node.Axis, _ ratio: CGFloat) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let width = ((rect.width - Self.divider) * ratio).rounded()
            return (CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                    CGRect(x: rect.minX + width + Self.divider, y: rect.minY,
                           width: rect.width - width - Self.divider, height: rect.height))
        case .vertical:
            let height = ((rect.height - Self.divider) * ratio).rounded()
            return (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height),
                    CGRect(x: rect.minX, y: rect.minY + height + Self.divider,
                           width: rect.width, height: rect.height - height - Self.divider))
        }
    }

    // MARK: Dividers

    /// Each visible divider and the split it belongs to.
    private var dividers: [(node: Node, rect: CGRect)] {
        guard !zoomed else { return [] }
        var result: [(Node, CGRect)] = []
        func collect(_ node: Node) {
            guard node.terminal == nil else { return }
            let first = node.children[0].frame
            let rect = node.axis == .horizontal
                ? CGRect(x: first.maxX, y: node.frame.minY, width: Self.divider, height: node.frame.height)
                : CGRect(x: node.frame.minX, y: first.maxY, width: node.frame.width, height: Self.divider)
            result.append((node, rect))
            node.children.forEach(collect)
        }
        collect(root)
        return result
    }

    /// The 1pt line is hard to hit, so the grab area is wider than what is drawn.
    private func grabArea(_ divider: (node: Node, rect: CGRect)) -> CGRect {
        divider.node.axis == .horizontal ? divider.rect.insetBy(dx: -3, dy: 0) : divider.rect.insetBy(dx: 0, dy: -3)
    }

    override func draw(_ dirtyRect: NSRect) {
        dividerColor.setFill()
        dividers.forEach { $0.rect.fill() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if dividers.contains(where: { grabArea($0).contains(local) }) { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        for divider in dividers {
            addCursorRect(grabArea(divider), cursor: divider.node.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragging = dividers.first { grabArea($0).contains(point) }?.node
    }

    override func mouseDragged(with event: NSEvent) {
        guard let node = dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let ratio = node.axis == .horizontal
            ? (point.x - node.frame.minX) / node.frame.width
            : (point.y - node.frame.minY) / node.frame.height
        node.ratio = min(max(ratio, 0.1), 0.9)
        needsLayout = true
    }

    override func mouseUp(with event: NSEvent) {
        if dragging != nil { onLayoutChange?() }
        dragging = nil
    }

    // MARK: Helpers

    private func adopt(_ terminal: TerminalView) {
        terminal.autoresizingMask = []
        terminal.onFocus = { [weak self, weak terminal] in
            if let self, let terminal { self.noteFocused(terminal) }
        }
        addSubview(terminal)
        needsLayout = true
    }

    private func applyFocus() {
        let single = terminals.count == 1 || zoomed
        for terminal in terminals {
            terminal.alphaValue = single || terminal === focused ? 1 : Self.unfocusedAlpha
        }
    }

    private func node(of terminal: TerminalView) -> Node? {
        func find(_ node: Node) -> Node? {
            if node.terminal === terminal { return node }
            return node.children.lazy.compactMap(find).first
        }
        return find(root)
    }

    /// The closest pane on that side of the focused one, preferring the one most in line with it.
    private func neighbor(_ direction: TerminalRequest.Direction) -> TerminalView? {
        let from = focused.frame
        let candidates = terminals.filter { $0 !== focused }.filter { other in
            let f = other.frame
            switch direction {
            case .left: return f.maxX <= from.minX + 1 && f.maxY > from.minY && f.minY < from.maxY
            case .right: return f.minX >= from.maxX - 1 && f.maxY > from.minY && f.minY < from.maxY
            case .up: return f.maxY <= from.minY + 1 && f.maxX > from.minX && f.minX < from.maxX
            case .down: return f.minY >= from.maxY - 1 && f.maxX > from.minX && f.minX < from.maxX
            }
        }
        return candidates.min { distance($0.frame, from) < distance($1.frame, from) }
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }
}

/// A session's panes as saved between launches: each terminal's folder, and each split's direction and share.
indirect enum PaneLayout: Codable {
    case terminal(directory: String)
    case split(horizontal: Bool, ratio: Double, first: PaneLayout, second: PaneLayout)

    var directories: [String] {
        switch self {
        case .terminal(let directory): [directory]
        case .split(_, _, let first, let second): first.directories + second.directories
        }
    }
}
