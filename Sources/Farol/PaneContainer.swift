import AppKit
import FarolCore
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
            chips.values.forEach { $0.apply(background: theme.background, foreground: theme.foreground) }
            applyFocus()
        }
    }
    /// Code colors for the file pane, from the same theme.
    var syntax: SyntaxColors? { didSet { if let syntax { file?.highlight(with: syntax) } } }
    private var dividerColor: NSColor { theme.background.mixed(with: theme.foreground, 0.11) }
    private var searchBar: SearchBar?
    /// Only panes you named have one.
    private var labels: [UUID: PaneLabel] = [:]
    /// The folder whose project's commands a pane offers, or nil where it has none to offer, like over ssh. Set by the store.
    var commandFolder: ((TerminalView) -> String?)?
    /// Runs a command in a new pane below, for a pane where a program like an agent is in front. Returns that pane.
    var runInNewPane: ((String) -> TerminalView?)?
    /// What each pane's folder offers, from the last look, so the right-click menu doesn't wait on the files.
    private var commands: [UUID: (folder: String, list: [ProjectCommand])] = [:]
    private var commandLookups: [UUID: UUID] = [:]
    /// The command started in each pane, kept while it runs, so ■ stops that command and never an agent.
    private var started: [UUID: ProjectCommand] = [:]
    private var runStates: [UUID: RunCommandState] = [:]
    private var runTokens: [UUID: UUID] = [:]
    private var listening: [UUID: [Int]] = [:]
    private var chips: [UUID: RunChip] = [:]
    private var hovered: TerminalView?
    private var hoverArea: NSTrackingArea?
    /// Settings → Appearance. On unless turned off.
    static let runButtonKey = "panes.runButton"
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

    /// Rebuilds saved panes. `make` creates a terminal in a folder, given the conversation its agent had. A file that is gone leaves its space to its neighbor.
    init(_ layout: PaneLayout, make: (String, AgentConversation?) -> TerminalView) {
        var names: [(TerminalView, String)] = []
        var file: FileView?
        func build(_ layout: PaneLayout) -> Node? {
            switch layout {
            case .terminal(let directory, let name, let conversation):
                let terminal = make(directory, conversation)
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
        root = build(layout) ?? Node(make(NSHomeDirectory(), nil))
        focused = root.leaves[0]
        super.init(frame: .zero)
        root.leaves.forEach(adopt)
        if let file {
            self.file = file
            adopt(file)
        }
        for (terminal, name) in names { labels[terminal.id] = makeLabel(for: terminal, name: name) }
    }

    func layoutSnapshot(conversations: [UUID: AgentConversation]) -> PaneLayout {
        func snapshot(_ node: Node) -> PaneLayout {
            if let terminal = node.terminal {
                return .terminal(directory: terminal.workingDirectory ?? NSHomeDirectory(), name: labels[terminal.id]?.name,
                                 conversation: conversations[terminal.id])
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
        chips.removeValue(forKey: terminal.id)?.removeFromSuperview()
        started[terminal.id] = nil
        runStates[terminal.id] = nil
        runTokens[terminal.id] = nil
        listening[terminal.id] = nil
        commands[terminal.id] = nil
        commandLookups[terminal.id] = nil
        if hovered === terminal { hovered = nil }
        terminal.removeFromSuperview()
        terminal.close()
        // The sibling that took the space can be the file pane, which holds no terminal.
        if terminal === focused { focus(parent.leaves.first ?? terminals[0]) }
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
        if visible, let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let terminal = terminals.first { !$0.isHidden && $0.frame.contains(point) }
            if terminal !== hovered { hover(terminal) }
        } else if !visible {
            hovered = nil
        }
        updateChips()
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
        placeChips()
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
        updateChips()
        bar.begin(with: needle)
    }

    private func hideSearch() {
        guard let bar = searchBar else { return }
        searchBar = nil
        bar.removeFromSuperview()
        if let terminal = bar.terminal { focus(terminal) }
        updateChips()
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

    // MARK: Run

    /// Follows the mouse over the panes, so ▶ shows only on the one you point at.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let terminal = terminals.first { !$0.isHidden && $0.frame.contains(point) }
        if terminal !== hovered { hover(terminal) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(nil)
    }

    private func hover(_ terminal: TerminalView?) {
        hovered = terminal
        updateChips()
        guard let terminal, !terminal.runsProgram, let folder = commandFolder?(terminal) else { return }
        let token = UUID()
        commandLookups[terminal.id] = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak terminal] in
            let list = Self.lookUp(folder)
            DispatchQueue.main.async {
                guard let self, let terminal, self.commandLookups[terminal.id] == token,
                      self.commandFolder?(terminal) == folder else { return }
                self.commands[terminal.id] = (folder, list)
                self.updateChips()
            }
        }
    }

    /// A shell can report its folder after the mouse is already over the pane.
    func commandFolderDidChange(in terminal: TerminalView) {
        if terminal === hovered { hover(terminal) }
    }

    /// Reads the project's files and asks git where the checkout's top is, so not on the main thread unless there is no other way.
    private static func lookUp(_ folder: String) -> [ProjectCommand] {
        ProjectCommands.find(in: folder, top: Git.topLevel(of: folder))
    }

    /// What a pane's folder offers: from the last look when the folder is the same, else read now.
    private func commandList(for terminal: TerminalView) -> [ProjectCommand] {
        guard let folder = commandFolder?(terminal) else { return [] }
        if let cached = commands[terminal.id], cached.folder == folder { return cached.list }
        let list = Self.lookUp(folder)
        commands[terminal.id] = (folder, list)
        return list
    }

    /// Typed at the pane's prompt. With a program like an agent in front, in a new pane below, so it never types into the agent.
    func run(_ command: ProjectCommand, in terminal: TerminalView) {
        let line = command.line(from: terminal.workingDirectory)
        guard !terminal.runsProgram else {
            if let pane = runInNewPane?(line) { track(command, in: pane) }
            return
        }
        focus(terminal)
        terminal.pasteText(line)
        terminal.press(.enter)
        track(command, in: terminal)
    }

    /// ■ and the ports show for what a pane runs from here. A dev server takes a moment to listen, so its ports are read a few times early on.
    private func track(_ command: ProjectCommand, in terminal: TerminalView) {
        started[terminal.id] = command
        runStates[terminal.id] = RunCommandState(startedAt: Date())
        let token = UUID()
        runTokens[terminal.id] = token
        listening[terminal.id] = []
        pollRun(in: terminal, token: token, after: 0.5)
        updateChips()
    }

    private func pollRun(in terminal: TerminalView, token: UUID, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak terminal] in
            guard let self, let terminal, self.runTokens[terminal.id] == token else { return }
            self.commandMayHaveChanged(in: terminal)
            if self.runTokens[terminal.id] == token { self.pollRun(in: terminal, token: token, after: 5) }
        }
    }

    /// The store calls this at each new title or prompt, which is when a command starts or ends.
    func commandMayHaveChanged(in terminal: TerminalView) {
        guard var state = runStates[terminal.id], let token = runTokens[terminal.id] else { return }
        let runsProgram = terminal.runsProgram
        guard state.observe(runsProgram: runsProgram, at: Date()) else {
            started[terminal.id] = nil
            runStates[terminal.id] = nil
            runTokens[terminal.id] = nil
            listening[terminal.id] = nil
            return updateChips()
        }
        runStates[terminal.id] = state
        guard runsProgram, let root = terminal.rootProcess else { return updateChips() }
        DispatchQueue.global(qos: .utility).async { [weak self, weak terminal] in
            let ports = Ports.listening(under: [root])
            DispatchQueue.main.async {
                guard let self, let terminal, self.runTokens[terminal.id] == token, self.listening[terminal.id] != ports else { return }
                self.listening[terminal.id] = ports
                self.updateChips()
            }
        }
        updateChips()
    }

    private func stop(_ terminal: TerminalView) {
        terminal.pressControl("c")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak terminal] in
            if let self, let terminal { self.commandMayHaveChanged(in: terminal) }
        }
    }

    /// A pane that runs a command from here shows ■ and its ports. The pane under the mouse, at a prompt with something to run, shows ▶.
    /// Anything else, like an agent or vim in front, shows nothing, so the corner never interrupts it.
    private func updateChips() {
        let on = UserDefaults.standard.object(forKey: Self.runButtonKey) as? Bool ?? true
        for terminal in terminals {
            let look: RunChip.Look?
            if !on || terminal.isHidden {
                look = nil
            } else if started[terminal.id] != nil {
                look = .running(ports: listening[terminal.id] ?? [])
            } else if searchBar?.terminal !== terminal, terminal === hovered, !terminal.runsProgram,
                      commandFolder?(terminal) != nil {
                look = .play
            } else {
                look = nil
            }
            guard let look else {
                chips[terminal.id]?.isHidden = true
                continue
            }
            let chip = chips[terminal.id] ?? makeChip(for: terminal)
            chip.look = look
            chip.isHidden = false
        }
        placeChips()
    }

    private func makeChip(for terminal: TerminalView) -> RunChip {
        let chip = RunChip()
        chip.apply(background: theme.background, foreground: theme.foreground)
        chip.onPress = { [weak self, weak terminal, weak chip] in
            guard let self, let terminal, let chip else { return }
            if case .running = chip.look { return self.stop(terminal) }
            self.showRunMenu(for: terminal, at: NSPoint(x: 0, y: chip.bounds.maxY + 4), in: chip)
        }
        chips[terminal.id] = chip
        addSubview(chip, positioned: .above, relativeTo: nil)
        return chip
    }

    /// Top right of each pane, left of its name or search bar.
    private func placeChips() {
        for terminal in terminals {
            guard let chip = chips[terminal.id], !chip.isHidden else { continue }
            let occupied = searchBar?.terminal === terminal ? (searchBar?.frame.width ?? 0) + 6
                : labels[terminal.id].map { $0.isHidden ? 0 : $0.frame.width + 6 } ?? 0
            let width = chip.fittingWidth
            chip.frame = NSRect(x: terminal.frame.maxX - 10 - occupied - width, y: terminal.frame.minY + 8, width: width, height: 20)
        }
    }

    /// The commands as menu items, the same for ▶ and the right-click menu: the name, then what it types in the muted color, like ⌘P.
    private func runItems(for terminal: TerminalView) -> [NSMenuItem] {
        commandList(for: terminal).map { command in
            let item = ActionMenuItem(title: command.name) { [weak self, weak terminal] in
                if let self, let terminal { self.run(command, in: terminal) }
            }
            let title = NSMutableAttributedString(string: command.name + "  ", attributes: [.font: NSFont.menuFont(ofSize: 13)])
            title.append(NSAttributedString(string: command.command, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = title
            item.toolTip = "\(command.source) in \((command.folder as NSString).abbreviatingWithTildeInPath)"
            return item
        }
    }

    /// The keyboard shortcut opens the same choices as ▶ for the focused pane.
    func showRunMenu() {
        let terminal = focused
        showRunMenu(for: terminal, at: NSPoint(x: terminal.frame.maxX - 10, y: terminal.frame.minY + 32), in: self)
    }

    private func showRunMenu(for terminal: TerminalView, at point: NSPoint, in view: NSView) {
        guard let menu = runMenu(for: terminal) else { return NSSound.beep() }
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private func runMenu(for terminal: TerminalView) -> NSMenu? {
        guard commandFolder?(terminal) != nil else { return nil }
        let menu = NSMenu()
        let items = runItems(for: terminal)
        items.forEach(menu.addItem)
        if !items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ActionMenuItem(title: "Add Command…") { [weak self, weak terminal] in
            if let terminal { self?.addCommand(for: terminal) }
        })
        return menu
    }

    private func addCommand(for terminal: TerminalView) {
        guard let folder = commandFolder?(terminal) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak terminal] in
            let root = Git.topLevel(of: folder) ?? folder
            DispatchQueue.main.async {
                guard let self, let terminal, let window = self.window else { return }
                let name = NSTextField(frame: NSRect(x: 0, y: 32, width: 300, height: 24))
                name.placeholderString = "Name, e.g. Preview site"
                let script = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                script.placeholderString = "Command, e.g. npm run dev"
                let fields = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
                fields.addSubview(name)
                fields.addSubview(script)
                let alert = NSAlert()
                alert.messageText = "Add Project Command"
                alert.informativeText = "Save a shell command in .farol/commands/ at \((root as NSString).abbreviatingWithTildeInPath). Edit its file later for multiple lines."
                alert.accessoryView = fields
                alert.addButton(withTitle: "Add")
                alert.addButton(withTitle: "Cancel")
                alert.beginSheetModal(for: window) { [weak self, weak terminal] response in
                    guard response == .alertFirstButtonReturn, let self, let terminal else { return }
                    do {
                        try ProjectCommands.save(name: name.stringValue, script: script.stringValue, in: root)
                        self.commands[terminal.id] = nil
                        self.commandLookups[terminal.id] = nil
                        if self.hovered === terminal { self.hover(terminal) }
                    } catch {
                        NSAlert(error: error).beginSheetModal(for: window)
                    }
                }
            }
        }
    }

    /// Run in the right-click menu for local panes, including where the project has no commands yet.
    private func addRunMenu(to menu: NSMenu, for terminal: TerminalView) {
        guard let submenu = runMenu(for: terminal) else { return }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Run", action: nil, keyEquivalent: "").submenu = submenu
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
        terminal.onContextMenu = { [weak self, weak terminal] menu in
            guard let self, let terminal else { return }
            self.addRunMenu(to: menu, for: terminal)
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
        file.onOpenFile = { [weak self] in self?.open($0) }
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

/// A session's panes as saved between launches: each terminal's folder, name and agent conversation, the open file, and each split's direction and share.
indirect enum PaneLayout: Codable {
    /// `name` and `conversation` are optional, so layouts saved before them still load.
    case terminal(directory: String, name: String? = nil, conversation: AgentConversation? = nil)
    case file(path: String)
    case split(horizontal: Bool, ratio: Double, first: PaneLayout, second: PaneLayout)

    var directories: [String] {
        switch self {
        case .terminal(let directory, _, _): [directory]
        case .file: []
        case .split(_, _, let first, let second): first.directories + second.directories
        }
    }
}
