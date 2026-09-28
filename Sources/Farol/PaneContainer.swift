import AppKit
import GhosttyTerminal

/// A session's terminals and at most one open file, split into panes. Each split holds two children and the share the first one gets.
/// Layout is plain arithmetic on that tree, which maps directly onto Ghostty's resize and equalize requests.
final class PaneContainer: NSView {
    final class Node {
        enum Axis { case horizontal, vertical }

        var terminal: TerminalView?
        var file: FileView?
        var axis = Axis.horizontal
        var children: [Node] = []
        var ratio: CGFloat = 0.5
        weak var parent: Node?
        fileprivate var frame = CGRect.zero

        /// A leaf with a terminal, or an empty split node when nil.
        init(_ terminal: TerminalView?) {
            self.terminal = terminal
        }

        init(file: FileView) {
            self.file = file
        }

        /// What a leaf shows. Nil for a split.
        var view: NSView? { terminal ?? file }

        var leaves: [TerminalView] { terminal.map { [$0] } ?? children.flatMap(\.leaves) }
    }

    private static let divider: CGFloat = 1
    private static let unfocusedAlpha: CGFloat = 0.7

    private(set) var root: Node
    /// The terminal with focus, or the last one that had it while the file pane has focus.
    private(set) var focused: TerminalView
    /// Opening another file replaces what it shows, so a session never fills up with file panes.
    private(set) var file: FileView?
    private(set) var fileFocused = false
    private var zoomed = false
    private var dragging: Node?

    /// The terminal theme's background and text colors, which the dividers and search bar are mixed from.
    var theme = (background: NSColor.black, foreground: NSColor.white) {
        didSet {
            needsDisplay = true
            searchBar?.apply(background: theme.background, foreground: theme.foreground)
            file?.apply(background: theme.background, foreground: theme.foreground)
            applyFocus()
        }
    }
    /// Code colors for the file pane, from the same theme.
    var syntax: SyntaxColors? { didSet { if let syntax { file?.highlight(with: syntax) } } }
    private var dividerColor: NSColor { theme.background.mixed(with: theme.foreground, 0.11) }
    private var searchBar: SearchBar?
    /// Only panes you named have one.
    private var labels: [UUID: PaneLabel] = [:]
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

    /// Rebuilds saved panes. `make` creates a terminal in a folder. A file that is gone leaves its space to its neighbor.
    init(_ layout: PaneLayout, make: (String) -> TerminalView) {
        var names: [(TerminalView, String)] = []
        var file: FileView?
        func build(_ layout: PaneLayout) -> Node? {
            switch layout {
            case .terminal(let directory, let name):
                let terminal = make(directory)
                if let name { names.append((terminal, name)) }
                return Node(terminal)
            case .file(let path):
                guard file == nil, FileManager.default.fileExists(atPath: path) else { return nil }
                file = FileView(path: path)
                return Node(file: file!)
            case .split(let horizontal, let ratio, let first, let second):
                guard let a = build(first) else { return build(second) }
                guard let b = build(second) else { return a }
                let node = Node(nil)
                node.axis = horizontal ? .horizontal : .vertical
                node.ratio = CGFloat(ratio)
                node.children = [a, b]
                node.children.forEach { $0.parent = node }
                return node
            }
        }
        // A layout always has a terminal, since closing the last one closes the session.
        root = build(layout) ?? Node(make(NSHomeDirectory()))
        focused = root.leaves[0]
        super.init(frame: .zero)
        root.leaves.forEach(adopt)
        if let file {
            self.file = file
            adopt(file)
        }
        for (terminal, name) in names { labels[terminal.id] = makeLabel(for: terminal, name: name) }
    }

    var layoutSnapshot: PaneLayout {
        func snapshot(_ node: Node) -> PaneLayout {
            if let terminal = node.terminal {
                return .terminal(directory: terminal.workingDirectory ?? NSHomeDirectory(), name: labels[terminal.id]?.name)
            }
            if let file = node.file { return .file(path: file.path) }
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
        insert(Node(terminal), beside: fileFocused ? file! : focused, direction)
        adopt(terminal)
        focus(terminal)
        onLayoutChange?()
    }

    /// Shows the file in the file pane, opening one right of the focused terminal if there is none yet.
    /// `line` scrolls to it, for opening a file at a change.
    func open(_ path: String, line: Int? = nil) {
        if let file {
            guard file.path != path else {
                if let line { file.reveal(line: line) }
                return focusFile()
            }
            return file.confirmClose { [weak self, weak file] in
                file?.show(path)
                if let line { file?.reveal(line: line) }
                self?.focusFile()
                self?.onLayoutChange?()
            }
        } else {
            let file = FileView(path: path)
            self.file = file
            insert(Node(file: file), beside: focused, .right)
            adopt(file)
            if let line { file.reveal(line: line) }
        }
        focusFile()
        onLayoutChange?()
    }

    private func focusFile() {
        if let file { window?.makeFirstResponder(file.textView) }
    }

    /// Asks first when the file has unsaved edits.
    func closeFile() {
        file?.confirmClose { [weak self] in self?.removeFile() }
    }

    private func removeFile() {
        guard let file, let leaf = node(of: file) else { return }
        self.file = nil
        detach(leaf)
        file.removeFromSuperview()
        if fileFocused { focus(focused) }
        fileFocused = false
        onLayoutChange?()
    }

    /// Removes a terminal pane and lets its sibling take the space. Returns false for the last terminal.
    func remove(_ terminal: TerminalView) -> Bool {
        guard terminals.count > 1, let leaf = node(of: terminal) else { return false }
        let parent = detach(leaf)
        if searchBar?.terminal === terminal { hideSearch() }
        labels.removeValue(forKey: terminal.id)?.removeFromSuperview()
        terminal.removeFromSuperview()
        if terminal === focused { focus(parent.leaves[0]) }
        onLayoutChange?()
        return true
    }

    /// Turns the leaf showing `view` into a split of it and `new`.
    private func insert(_ new: Node, beside view: NSView, _ direction: TerminalRequest.Direction) {
        guard let leaf = node(of: view) else { return }
        let old = leaf.terminal.map { Node($0) } ?? Node(file: leaf.file!)
        leaf.terminal = nil
        leaf.file = nil
        leaf.axis = direction == .left || direction == .right ? .horizontal : .vertical
        leaf.children = direction == .left || direction == .up ? [new, old] : [old, new]
        leaf.ratio = 0.5
        leaf.children.forEach { $0.parent = leaf }
        zoomed = false
        needsLayout = true
    }

    /// Takes a leaf out and moves its sibling into the parent's place. Returns that parent.
    @discardableResult
    private func detach(_ leaf: Node) -> Node {
        let parent = leaf.parent!
        let sibling = parent.children.first { $0 !== leaf }!
        parent.terminal = sibling.terminal
        parent.file = sibling.file
        parent.axis = sibling.axis
        parent.children = sibling.children
        parent.ratio = sibling.ratio
        parent.children.forEach { $0.parent = parent }
        zoomed = false
        needsLayout = true
        return parent
    }

    /// Moves keyboard focus. The terminal reports back through onFocus, which records it.
    func focus(_ target: TerminalView) {
        if window?.makeFirstResponder(target) != true { noteFocused(target) }
    }

    /// Where keyboard focus goes when the session is shown again.
    var focusTarget: NSView { fileFocused ? file!.textView : focused }

    private func noteFocused(_ target: TerminalView) {
        focused = target
        fileFocused = false
        applyFocus()
        onFocusChange?(target)
    }

    /// Every pane in screen order, the file pane included.
    private var panes: [NSView] {
        func collect(_ node: Node) -> [NSView] { node.view.map { [$0] } ?? node.children.flatMap(collect) }
        return collect(root)
    }

    private var focusedPane: NSView { fileFocused ? file! : focused }

    func goto(_ target: TerminalRequest.SplitTarget) {
        let all = panes
        guard all.count > 1, let index = all.firstIndex(where: { $0 === focusedPane }) else { return }
        switch target {
        case .previous: focus(pane: all[(index - 1 + all.count) % all.count])
        case .next: focus(pane: all[(index + 1) % all.count])
        case .direction(let direction): neighbor(direction).map { focus(pane: $0) }
        }
    }

    private func focus(pane: NSView) {
        if let terminal = pane as? TerminalView { focus(terminal) } else { focusFile() }
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
            file?.isHidden = true
            place(leaf, in: bounds)
        } else {
            terminals.forEach { $0.isHidden = false }
            file?.isHidden = false
            place(root, in: bounds)
        }
        applyFocus()
        placeLabels()
        placeSearchBar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func place(_ node: Node, in rect: CGRect) {
        node.frame = rect
        if let view = node.view {
            view.frame = rect.integral
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

    // MARK: Search

    /// The pane search acts on: the one showing the bar, or the focused one.
    var searchTarget: TerminalView { searchBar?.terminal ?? focused }

    private func showSearch(in terminal: TerminalView, needle: String) {
        if let bar = searchBar, bar.terminal !== terminal {
            bar.terminal?.endSearch()
            hideSearch()
        }
        let bar = searchBar ?? SearchBar(for: terminal)
        bar.apply(background: theme.background, foreground: theme.foreground)
        bar.onClose = { [weak self, weak terminal] in
            terminal?.endSearch()
            self?.hideSearch()
        }
        searchBar = bar
        placeSearchBar()
        bar.begin(with: needle)
    }

    private func hideSearch() {
        guard let bar = searchBar else { return }
        searchBar = nil
        bar.removeFromSuperview()
        if let terminal = bar.terminal { focus(terminal) }
    }

    /// Top right of its pane, above every terminal.
    private func placeSearchBar() {
        guard let bar = searchBar, let terminal = bar.terminal else { return }
        let size = SearchBar.size
        bar.frame = NSRect(x: terminal.frame.maxX - size.width - 10, y: terminal.frame.minY + 8,
                           width: min(size.width, terminal.frame.width - 20), height: size.height)
        if subviews.last !== bar { addSubview(bar, positioned: .above, relativeTo: nil) }
    }

    // MARK: Names

    /// Shows the focused pane's label ready for typing, adding one if the pane has no name yet.
    func nameFocusedPane() {
        let label = labels[focused.id] ?? makeLabel(for: focused, name: "")
        labels[focused.id] = label
        needsLayout = true
        layoutSubtreeIfNeeded()
        label.beginEditing()
    }

    @objc private func nameFromMenu() { nameFocusedPane() }

    private func makeLabel(for terminal: TerminalView, name: String) -> PaneLabel {
        let label = PaneLabel()
        label.name = name
        label.onCommit = { [weak self, weak terminal] name in
            guard let self, let terminal else { return }
            if name == nil { self.labels.removeValue(forKey: terminal.id)?.removeFromSuperview() }
            self.needsLayout = true
            self.focus(terminal)
            self.onLayoutChange?()
        }
        return label
    }

    /// Top right of each named pane. The search bar takes that corner while it is open.
    private func placeLabels() {
        for terminal in terminals {
            guard let label = labels[terminal.id] else { continue }
            label.isHidden = terminal.isHidden || searchBar?.terminal === terminal
            let width = min(label.fittingWidth, terminal.frame.width - 20)
            label.frame = NSRect(x: terminal.frame.maxX - width - 10, y: terminal.frame.minY + 8, width: width, height: 20)
            if label.superview == nil { addSubview(label, positioned: .above, relativeTo: terminal) }
        }
    }

    // MARK: Dividers

    /// Each visible divider and the split it belongs to.
    private var dividers: [(node: Node, rect: CGRect)] {
        guard !zoomed else { return [] }
        var result: [(Node, CGRect)] = []
        func collect(_ node: Node) {
            guard node.view == nil else { return }
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
        terminal.onSearchStart = { [weak self, weak terminal] needle in
            if let self, let terminal { self.showSearch(in: terminal, needle: needle) }
        }
        terminal.onContextMenu = { [weak self] menu in
            guard let self else { return }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Name Pane…", action: #selector(self.nameFromMenu), keyEquivalent: "").target = self
            // Same path as ⌘W, so a running program still asks before it closes.
            menu.addItem(withTitle: self.terminals.count > 1 ? "Close Pane" : "Close Session",
                         action: #selector(AppDelegate.closeSession(_:)), keyEquivalent: "")
        }
        terminal.onSearchEnd = { [weak self, weak terminal] in
            if self?.searchBar?.terminal === terminal { self?.hideSearch() }
        }
        addSubview(terminal)
        needsLayout = true
    }

    private func adopt(_ file: FileView) {
        file.autoresizingMask = []
        file.apply(background: theme.background, foreground: theme.foreground)
        if let syntax { file.highlight(with: syntax) }
        file.onFocus = { [weak self] in
            self?.fileFocused = true
            self?.applyFocus()
        }
        file.onClose = { [weak self] in self?.closeFile() }
        addSubview(file)
        needsLayout = true
    }

    private func applyFocus() {
        let single = (terminals.count == 1 && file == nil) || zoomed
        for terminal in terminals {
            let active = terminal === focused && !fileFocused
            terminal.alphaValue = single || active ? 1 : Self.unfocusedAlpha
            labels[terminal.id]?.apply(background: theme.background, foreground: theme.foreground, focused: active)
        }
        file?.alphaValue = single || fileFocused ? 1 : Self.unfocusedAlpha
    }

    private func node(of view: NSView) -> Node? {
        func find(_ node: Node) -> Node? {
            if node.view === view { return node }
            return node.children.lazy.compactMap(find).first
        }
        return find(root)
    }

    /// The closest pane on that side of the focused one, preferring the one most in line with it.
    private func neighbor(_ direction: TerminalRequest.Direction) -> NSView? {
        let from = focusedPane.frame
        let candidates = panes.filter { $0 !== focusedPane }.filter { other in
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

/// A session's panes as saved between launches: each terminal's folder and name, the open file, and each split's direction and share.
indirect enum PaneLayout: Codable {
    /// `name` is optional, so layouts saved before panes had names still load.
    case terminal(directory: String, name: String? = nil)
    case file(path: String)
    case split(horizontal: Bool, ratio: Double, first: PaneLayout, second: PaneLayout)

    var directories: [String] {
        switch self {
        case .terminal(let directory, _): [directory]
        case .file: []
        case .split(_, _, let first, let second): first.directories + second.directories
        }
    }
}
