import AppKit
import FarolCore
import GhosttyTerminal

/// A file's text with line numbers, in a tab of the file pane, which shows its name and actions.
/// Edits are saved with ⌘S. When an agent changes the file on disk, it reloads, or asks if you have unsaved edits.
final class FileView: NSView {
    private static let barHeight: CGFloat = 30

    private(set) var path = ""
    private var language: Syntax.Language?
    private var syntax: SyntaxColors?
    private var plainColor = NSColor.textColor
    private var pendingHighlight: DispatchWorkItem?
    /// Up to this, a file opens already colored and lays out whole, which is cheap and never misdraws a line while typing.
    /// Past it, only what is on screen is laid out, since laying out 2 MB to reach the end takes a second, and coloring would redo it.
    private static let large = 200_000
    /// A large file's colors, kept rather than written into the text, which would take seconds. Only the lines on screen get them.
    private var tokens: [Syntax.Token] = []
    /// The length `fitLayout` last saw. A change far bigger than typing, like formatting, undoing it or a paste, fits the layout again.
    private var fittedLength = 0
    private var isLarge: Bool { (text.textStorage?.length ?? 0) > Self.large }
    /// Bumped on every edit and every coloring, so colors read from an older text are dropped rather than put on the wrong characters.
    private var highlightGeneration = 0
    /// Lines wrap only in a file with a very long line, which would lag every mouse move otherwise.
    private var wraps = false {
        didSet {
            guard wraps != oldValue, let container = text.textContainer else { return }
            text.isHorizontallyResizable = !wraps
            container.widthTracksTextView = wraps
            if !wraps { container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude) }
            needsLayout = true
        }
    }
    private(set) var isDirty = false {
        didSet {
            blame.lines = isDirty ? [] : blameLines
            if isDirty != oldValue { onStateChange?() }
        }
    }
    /// The file, its unsaved state or its mode changed, for the tab bar to follow.
    var onStateChange: (() -> Void)?
    /// The cursor moved or the selection changed, for the status bar.
    var onCursorChange: (() -> Void)?

    /// Where the cursor is, from 1, and how many characters are selected. From the gutter's index of lines, so a move costs nothing.
    var cursor: (line: Int, column: Int, selected: Int) {
        let range = text.selectedRange()
        let line = gutter.line(containing: range.location)
        // While typing, the selection can move before the gutter counts the new lines, so the column never goes below 1.
        return (line.index + 1, max(1, range.location - line.start + 1), range.length)
    }
    var onFocus: (() -> Void)?
    /// Opens another file in this pane, from a link in the Markdown preview.
    var onOpenFile: ((String) -> Void)?
    /// Shows a commit, by its hash, in the git graph, from a click on a line's hash in the blame.
    var onShowCommit: ((String) -> Void)?
    /// Opens a file at a line, from a ⌘-click on a name the language server placed there.
    var onOpenAt: ((String, Int) -> Void)?
    /// ⌥⌘ with an arrow while the text has the keyboard: go to the pane that way, as in a terminal.
    var onMovePane: ((TerminalRequest.Direction) -> Void)?
    /// ⇧⌘↩, which zooms a terminal pane, zooms the file pane here.
    var onZoom: (() -> Void)?
    /// The theme's colors, for the list of definitions or references to look like the rest of Farol.
    var palette: () -> Palette? = { nil }
    /// The pane now shows another file, which the files panel follows.
    var onPathChange: (() -> Void)?
    /// The session's agent by name, and whether it can take text now. Nil when none runs.
    var agent: () -> (name: String, ready: Bool)? = { nil }
    /// Puts lines of a file in the agent's prompt, with what's wrong there when the language server found a problem in them.
    var onSendToAgent: ((String, ClosedRange<Int>, String?) -> Void)?
    /// A click on a change mark: the review panel shows this file's changes.
    var onShowChanges: ((String) -> Void)?
    /// The language server's problems in this file changed, for the status bar's counts.
    var onProblemsChange: (() -> Void)?

    /// The file as last read or saved, to tell our own save from someone else's change.
    private var onDisk: String?
    private var watcher: DispatchSourceFileSystemObject?

    /// Who last changed each line, left of the numbers. Off until you ask, and your choice holds for every file, like the Markdown preview.
    private var blaming = false
    private static let blameKey = "FarolFileBlame"
    /// The file is in a git checkout, so there is something to blame.
    private var inCheckout = false
    private var blameLines: [Blame.Line] = []
    /// Git can't blame this file, as when it isn't tracked, so no column waits for an answer.
    private var blameMissing = false
    private var blameGeneration = 0
    private let blame: BlameColumn
    /// The file as of the last commit, which the marks beside the numbers compare with. Nil outside a checkout or for an ignored file.
    private var changeBase: String?
    private var changeGeneration = 0
    private var pendingChanges: DispatchWorkItem?
    /// Watches the repo's refs, so a commit, by you or an agent, clears the marks it took in.
    private var refsWatcher: FolderWatcher?
    /// Markdown reads as source or rendered. Source until you first pick the preview, then your choice holds for every Markdown file.
    private var previewing = false
    private static let previewKey = "FarolMarkdownPreview"
    private let preview = MarkdownView()
    private var themeColors: (background: NSColor, foreground: NSColor)?
    /// Shown when the file changed on disk while you had unsaved edits.
    private let conflict = NSView()
    private let conflictText = NSTextField(labelWithString: "Changed on disk while you were editing.")
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let keepButton = NSButton(title: "Keep Mine", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let text: CodeTextView
    private lazy var links = DefinitionLinks(text: text)
    private let gutter: LineNumbers
    /// The line a search or a link opened the file at, lit until the cursor leaves it.
    private var litLine: NSRange?
    /// Every match of the search that opened the file, marked until you edit it or open it otherwise.
    private var marks: [NSRange] = []
    /// Shown instead of the text for binary files, files too big to open, or errors.
    private let message = NSTextField(labelWithString: "")

    init(path: String) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        text = CodeTextView(frame: .zero, textContainer: container)
        gutter = LineNumbers(textView: text)
        blame = BlameColumn(gutter: gutter)
        super.init(frame: .zero)
        wantsLayer = true

        blame.onShowCommit = { [weak self] in self?.onShowCommit?($0) }
        text.leadingMenuItems = { [weak self] in
            guard let self, canSendToAgent, let agent = agent() else { return [] }
            let item = ActionMenuItem(title: "Send to \(agent.name)") { [weak self] in self?.sendToAgent() }
            // Only shown, so the menu teaches the keys.
            item.keyEquivalent = "l"
            item.keyEquivalentModifierMask = [.command, .shift]
            item.isEnabled = agent.ready
            return [item]
        }
        text.extraMenuItems = { [weak self] in
            guard let self else { return [] }
            var items: [NSMenuItem] = []
            if canFormat {
                items.append(ActionMenuItem(title: "Format JSON") { [weak self] in self?.reformatJSON(pretty: true) })
                items.append(ActionMenuItem(title: "Minify JSON") { [weak self] in self?.reformatJSON(pretty: false) })
            }
            if canBlame {
                items.append(ActionMenuItem(title: blaming ? "Hide Git Blame" : "Show Git Blame") { [weak self] in self?.toggleBlame() })
            }
            if let server = serverMenu() { items.append(server) }
            return items
        }
        blame.contextMenu = { [weak self] in self?.blameMenu(for: $0) }
        gutter.contextMenu = { [weak self] in self?.blameMenu(for: nil) }

        conflict.wantsLayer = true
        conflict.isHidden = true
        conflictText.font = .systemFont(ofSize: 12)
        for (button, action) in [(reloadButton, #selector(reloadFromDisk)), (keepButton, #selector(keepMine))] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
            conflict.addSubview(button)
        }
        conflict.addSubview(conflictText)

        CodeText.configure(text)
        text.allowsUndo = true
        // Code keeps its lines: no wrapping, scroll sideways instead.
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = []
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        container.widthTracksTextView = false
        text.textContainerInset = NSSize(width: 8, height: 6)
        text.onFocus = { [weak self] in self?.onFocus?() }
        links.open = { [weak self] in self?.onOpenAt?($0, $1) }
        links.palette = { [weak self] in self?.palette() }
        links.onLink = { [weak text] in text?.linkRect = $0 }
        text.commandLinks = { [weak self] in self.map { LanguageServers.shared.isEnabled(for: $0.path) } ?? false }
        text.onCommandClick = { [weak self] in self?.links.click(at: $0) }
        text.onCommandHover = { [weak self] in self?.links.hover(at: $0) }
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: text, queue: .main) { [weak self] _ in
            guard let self else { return }
            // Typing a line and deleting it again leaves nothing to save.
            isDirty = text.string != onDisk
            if abs((text.textStorage?.length ?? 0) - fittedLength) > 10_000 { fitLayout(text.string) }
            // The observer runs on the main queue, which the compiler can't see. This checks it, rather than hiding the warning.
            MainActor.assumeIsolated { self.links.textChanged() }
            unmark()
            gutter.textChanged()
            highlightSoon()
            markChangesSoon()
        }

        NotificationCenter.default.addObserver(forName: LanguageServers.diagnosticsDidChange, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? String == path else { return }
            MainActor.assumeIsolated { self.showProblems() }
        }
        // An edit moves the problems after it along, so their squiggles stay under their words until the server answers again.
        NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: text.textStorage, queue: nil) { [weak self] note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { self?.text.shiftProblems(after: storage.editedRange, by: storage.changeInLength) }
        }
        text.onMouseOver = { [weak self] in self?.hover(at: $0) }

        NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: text, queue: .main) { [weak self] _ in
            guard let self else { return }
            gutter.needsDisplay = true
            onCursorChange?()
            guard let line = litLine, !NSLocationInRange(text.selectedRange().location, line) else { return }
            unlight()
        }

        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            self?.gutter.needsDisplay = true
            self?.blame.needsDisplay = true
            self?.colorVisible()
        }

        message.alignment = .center
        message.isHidden = true

        preview.text.onFocus = { [weak self] in self?.onFocus?() }
        preview.onOpenFile = { [weak self] in self?.onOpenFile?($0) }

        gutter.onResize = { [weak self] in self?.needsLayout = true }
        gutter.markColors = { [weak self] in
            self?.palette().map { (NSColor($0.added), NSColor($0.pull), NSColor($0.removed)) }
        }
        gutter.onClickMark = { [weak self] in
            guard let self else { return }
            onShowChanges?(path)
        }
        for view in [conflict, blame, gutter, scroll, preview, message] { addSubview(view) }
        show(path)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { watcher?.cancel() }

    override var isFlipped: Bool { true }

    /// The pane an arrow with ⌥⌘ points to. Ghostty reads the same keys while a terminal has the keyboard.
    /// Text has no use for them, so here they only move between panes. The arrow keys add the numeric pad and function flags to the event.
    /// Caps Lock is left out, as a terminal leaves it out.
    static func paneDirection(of event: NSEvent) -> TerminalRequest.Direction? {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock]) == [.command, .option] else { return nil }
        switch event.keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }

    /// Only when the keyboard is in this file, since a terminal beside it has the same keys and handles them itself.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: event)
        }
        if let direction = Self.paneDirection(of: event) {
            onMovePane?(direction)
            return true
        }
        if Self.isZoom(event) {
            onZoom?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⇧⌘↩ or ⇧⌘ and the keypad's enter, as Ghostty reads them for its split zoom.
    static func isZoom(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock]) == [.command, .shift]
            && [36, 76].contains(event.keyCode)
    }

    /// The text that takes the keyboard: the preview while it shows, else the source.
    var textView: NSTextView { showsPreview ? preview.text : text }

    /// The text selected in what the pane shows, or nil without a selection.
    var selectedText: String? {
        let range = textView.selectedRange()
        return range.length > 0 ? (textView.string as NSString).substring(with: range) : nil
    }

    /// A click on the line numbers picks this pane too, so ⌘W closes the file and not a terminal.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }

    // MARK: Markdown preview

    private var showsPreview: Bool { Markdown.handles(path) && previewing && message.isHidden }

    /// Markdown reads as source or rendered.
    var canPreview: Bool { Markdown.handles(path) && message.isHidden }
    var isPreviewing: Bool { previewing }
    /// A checkout's file shown as source has someone to blame for each line.
    var canBlame: Bool { inCheckout && !scroll.isHidden }
    var isBlaming: Bool { blaming }

    func togglePreview() {
        let focused = window?.firstResponder === textView
        previewing.toggle()
        UserDefaults.standard.set(previewing, forKey: Self.previewKey)
        updateMode()
        if focused { window?.makeFirstResponder(textView) }
    }

    /// Shows the source or the preview. The preview reads the text being edited, so unsaved edits show too.
    private func updateMode() {
        preview.isHidden = !showsPreview
        scroll.isHidden = !message.isHidden || showsPreview
        gutter.isHidden = scroll.isHidden
        blame.isHidden = !showsBlame
        if showsPreview { preview.show(text.string, path: path) }
        needsLayout = true
        onStateChange?()
    }

    /// Loads another file into the same pane. Callers check `isDirty` first, see confirmClose.
    func show(_ path: String) {
        self.path = path
        // Read for each file, so a choice made in another pane holds here too.
        previewing = UserDefaults.standard.bool(forKey: Self.previewKey)
        blaming = UserDefaults.standard.bool(forKey: Self.blameKey)
        inCheckout = false
        changeBase = nil
        refsWatcher = nil
        gutter.marks = []
        text.problems = []
        blameMissing = false
        blameGeneration += 1
        blameLines = []
        blame.lines = []
        language = Syntax.language(for: path)
        text.comment = language?.comment
        load(keepingPosition: false)
        watch()
        findFolder()
        links.path = path
        onPathChange?()
    }

    /// The language server's menu, the status bar's own, in the code's right-click menu too, where turning it on is a click.
    private func serverMenu() -> NSMenuItem? {
        guard let kind = LSP.server(for: path) else { return nil }
        // Off, one plain item rather than a submenu holding only it.
        guard LanguageServers.shared.isEnabled(kind) else {
            guard LanguageServers.shared.isInstalled(kind) != false else { return nil }
            return ActionMenuItem(title: "Enable Language Server") { LanguageServers.shared.setEnabled(true, for: kind) }
        }
        let item = NSMenuItem(title: "Language Server", action: nil, keyEquivalent: "")
        item.submenu = LanguageServerMenu.make(for: path) { [weak self] in self?.onOpenAt?($0, $1) }
        return item
    }

    /// Its tab came to the front, so its language server can start loading, if they are on.
    func warmLanguageServer() {
        links.warm()
    }

    /// Its tab closed, so the language server can forget the file.
    func closed() {
        links.closed()
    }

    /// Asks git whether the file is in a checkout, off the main thread, since only then is there someone to blame.
    private func findFolder() {
        let path = path
        let directory = (path as NSString).deletingLastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            let top = Git.topLevel(of: directory)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.path == path, let top, directory.hasPrefix(top + "/") else { return }
                self.inCheckout = true
                self.loadBlame()
                self.loadChangeBase()
                self.watchRefs()
                self.updateMode()
            }
        }
    }

    // MARK: Changes since the last commit

    /// Reads the committed version off the main thread, then marks the lines against it.
    private func loadChangeBase() {
        guard inCheckout else { return }
        let path = path
        DispatchQueue.global(qos: .userInitiated).async {
            let base = LineChanges.base(of: path)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.path == path else { return }
                changeBase = base
                markChanges()
            }
        }
    }

    private func watchRefs() {
        let path = path
        DispatchQueue.global(qos: .utility).async {
            let repo = Git.repoRoot(of: (path as NSString).deletingLastPathComponent)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.path == path, let repo else { return }
                refsWatcher = FolderWatcher((repo as NSString).appendingPathComponent(".git"), latency: 0.5) { [weak self] paths in
                    // A commit or a checkout moves a ref. The index changes far more often and says nothing new here.
                    guard paths.contains(where: { $0.hasSuffix("/HEAD") || $0.contains("/refs/") || $0.hasSuffix("/packed-refs") }) else { return }
                    self?.loadChangeBase()
                }
            }
        }
    }

    /// Typing waits for a pause, so a burst of keys compares once.
    private func markChangesSoon() {
        guard changeBase != nil else { return }
        pendingChanges?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.markChanges() }
        pendingChanges = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Compares in the background, so a large file never holds up a key. The last asked wins.
    private func markChanges() {
        changeGeneration += 1
        guard let base = changeBase, let storage = text.textStorage, message.isHidden else { return gutter.marks = [] }
        // Bridging copies the storage's mutable string, so the other thread reads text no edit can change.
        let (generation, current) = (changeGeneration, storage.string)
        DispatchQueue.global(qos: .userInitiated).async {
            let marks = LineChanges.marks(from: base, to: current)
            DispatchQueue.main.async { [weak self] in
                guard let self, changeGeneration == generation else { return }
                gutter.marks = marks
            }
        }
    }

    // MARK: Problems the language server found

    /// Errors and warnings get a squiggle, in the theme's red and yellow. Hints and notes would crowd the code, so they stay out.
    private func showProblems() {
        let found = (LanguageServers.shared.diagnostics[path] ?? []).filter { $0.severity == .error || $0.severity == .warning }
        let string = text.string as NSString
        let colors = palette().map { (error: NSColor($0.removed), warning: NSColor($0.waiting)) }
        text.problems = found.compactMap { diagnostic in
            guard let range = range(diagnostic, in: string) else { return nil }
            let color = diagnostic.severity == .error ? colors?.error ?? .systemRed : colors?.warning ?? .systemYellow
            return CodeTextView.Problem(range: range, color: color, diagnostic: diagnostic)
        }.sorted { $0.range.location < $1.range.location }
        onProblemsChange?()
    }

    /// The characters a problem is about. One about a single point, like a missing brace, covers the character there so it can be seen.
    private func range(_ diagnostic: LSP.Diagnostic, in string: NSString) -> NSRange? {
        func offset(_ position: LSP.Position) -> Int? {
            guard position.line < gutter.count else { return position.line == gutter.count ? string.length : nil }
            let start = gutter.start(ofLine: position.line)
            let line = string.lineRange(for: NSRange(location: start, length: 0))
            return min(start + position.character, NSMaxRange(line))
        }
        guard let start = offset(diagnostic.start), let end = offset(diagnostic.end) else { return nil }
        if end > start { return NSRange(location: start, length: end - start) }
        guard string.length > 0 else { return nil }
        let at = start < string.length && string.character(at: start) != 0x0A ? start : max(start - 1, 0)
        return NSRange(location: at, length: 1)
    }

    /// How many errors and warnings, for the status bar.
    var problemCounts: (errors: Int, warnings: Int) {
        let errors = text.problems.filter { $0.diagnostic.severity == .error }.count
        return (errors, text.problems.count - errors)
    }

    /// F8 and ⇧F8: the next problem after the cursor, round from the last to the first, selected with its message shown under it.
    func goToProblem(forward: Bool) {
        let problems = text.problems
        guard !problems.isEmpty, canSendToAgent else { return NSSound.beep() }
        let cursor = text.selectedRange().location
        let next = forward
            ? problems.first { $0.range.location > cursor } ?? problems[0]
            : problems.last { $0.range.location < cursor } ?? problems[problems.count - 1]
        window?.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: next.range.location, length: 0))
        text.scrollRangeToVisible(next.range)
        showCard(for: next)
    }

    /// What the mouse rests on: a problem's range, or a name the server may know about.
    private var hovered: NSRange?
    private var pendingInfo: DispatchWorkItem?

    /// Resting the mouse on a squiggle says what's wrong. On a name, with its language server on, a moment later its type and docs.
    private func hover(at index: Int?) {
        let problem = index.flatMap { index in text.problems.first { NSLocationInRange(index, $0.range) } }
        let target = problem?.range ?? index.flatMap { links.word(at: $0) }
        guard target != hovered else { return }
        hovered = target
        pendingInfo?.cancel()
        HoverTip.shared.hide()
        if let problem { return showCard(for: problem) }
        guard let index, let target, LanguageServers.shared.isEnabled(for: path) else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.links.info(at: index) { [weak self] info in
                guard let self, hovered == target, let info else { return }
                showCard(info, over: target)
            }
        }
        pendingInfo = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// The server's words, then who found it, muted, on the same line. The squiggle's color already says error or warning.
    /// Below, how to hand it to the agent, the fix most often wanted.
    private func showCard(for problem: CodeTextView.Problem) {
        let foreground = themeColors?.foreground ?? .labelColor
        let muted = themeColors.map { $0.background.mixed(with: $0.foreground, 0.55) } ?? .secondaryLabelColor
        let card = NSMutableAttributedString(string: problem.diagnostic.message, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: foreground])
        if let source = problem.diagnostic.source {
            card.append(NSAttributedString(string: "  " + source, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: muted]))
        }
        if let agent = agent(), agent.ready {
            card.append(NSAttributedString(string: "\n⇧⌘L  ", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: muted]))
            card.append(NSAttributedString(string: "Ask \(agent.name) to fix", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: muted]))
        }
        present(card, over: problem.range)
    }

    /// A hover's answer: its first line is the name's signature, so it reads as code, then the docs. Long docs are cut short.
    private func showCard(_ message: String, over range: NSRange) {
        let foreground = themeColors?.foreground ?? .labelColor
        var lines = message.components(separatedBy: "\n")
        if lines.count > 14 { lines = Array(lines.prefix(14)) + ["…"] }
        let card = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let font = index == 0 ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) : NSFont.systemFont(ofSize: 12)
            card.append(NSAttributedString(string: (index > 0 ? "\n" : "") + line, attributes: [.font: font, .foregroundColor: foreground]))
        }
        present(card, over: range)
    }

    /// Over the line, as editors put it, so the code you read next stays in view.
    private func present(_ card: NSAttributedString, over range: NSRange) {
        guard let window, let rect = text.rect(of: range) else { return }
        HoverTip.shared.show(card: card, below: window.convertToScreen(text.convert(rect, to: nil)), in: window, above: true)
    }

    // MARK: Git blame

    /// Keeps its width while there are unsaved edits, so the code doesn't jump. It is blank then, since git numbers the saved file.
    private var showsBlame: Bool { blaming && inCheckout && !blameMissing && !scroll.isHidden }

    func toggleBlame() {
        blaming.toggle()
        UserDefaults.standard.set(blaming, forKey: Self.blameKey)
        loadBlame()
        updateMode()
    }

    /// Right-clicking the line numbers or the column, where editors keep their blame.
    private func blameMenu(for line: Blame.Line?) -> NSMenu? {
        guard inCheckout else { return nil }
        let menu = NSMenu()
        if let line, line.isCommitted {
            menu.addItem(ActionMenuItem(title: "Show in Git Graph") { [weak self] in self?.onShowCommit?(line.hash) })
            menu.addItem(ActionMenuItem(title: "Copy Commit Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line.hash, forType: .string)
            })
            menu.addItem(.separator())
        }
        menu.addItem(ActionMenuItem(title: blaming ? "Hide Git Blame" : "Show Git Blame") { [weak self] in self?.toggleBlame() })
        return menu
    }

    /// Asks git who changed each line, off the main thread, and only while the column is on. The last asked wins.
    private func loadBlame() {
        blameGeneration += 1
        guard blaming, inCheckout else {
            blameLines = []
            blame.lines = []
            return
        }
        let (generation, path) = (blameGeneration, path)
        DispatchQueue.global(qos: .userInitiated).async {
            let lines = Blame.lines(of: path)
            DispatchQueue.main.async { [weak self] in
                guard let self, blameGeneration == generation else { return }
                blameMissing = lines == nil
                blameLines = lines ?? []
                blame.lines = isDirty ? [] : blameLines
                updateMode()
            }
        }
    }

    // MARK: The agent

    /// Source on screen, where lines have numbers to point at.
    var canSendToAgent: Bool { !scroll.isHidden }

    /// The lines the selection covers, from 1, or the cursor's line. A selection that ends at the start of a line leaves that line out.
    var selectedLines: ClosedRange<Int> {
        let range = text.selectedRange()
        let first = gutter.line(containing: range.location).index + 1
        let last = gutter.line(containing: range.length > 0 ? NSMaxRange(range) - 1 : range.location).index + 1
        return first...max(first, last)
    }

    func sendToAgent() {
        guard canSendToAgent else { return }
        let lines = selectedLines
        onSendToAgent?(path, lines, problemNote(in: lines))
    }

    /// The problems on those lines, in the server's words, so the agent knows what to fix without being told.
    private func problemNote(in lines: ClosedRange<Int>) -> String? {
        let messages = text.problems.filter { lines.contains(gutter.line(containing: $0.range.location).index + 1) }.map(\.diagnostic.message)
        let unique = messages.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.isEmpty ? nil : unique.joined(separator: " · ")
    }

    /// How many lines the file has, for Go to Line to say.
    var lineCount: Int { gutter.count }

    /// Go to Line: the line near the top, the cursor at the column, both clamped to what the file has.
    func goTo(line: Int, column: Int) {
        reveal(line: min(max(line, 1), lineCount))
        let string = text.string as NSString
        let start = text.selectedRange().location
        let end = NSMaxRange(string.lineRange(for: NSRange(location: start, length: 0)))
        let length = max(0, end - start - (end > start && string.character(at: end - 1) == 0x0A ? 1 : 0))
        text.setSelectedRange(NSRange(location: start + min(max(column - 1, 0), length), length: 0))
        window?.makeFirstResponder(text)
    }

    /// Puts the cursor on a line and scrolls it near the top, for opening a file at its first change.
    func reveal(line: Int) {
        // A line is a place in the source. The preview has no lines to go to.
        if showsPreview {
            previewing = false
            updateMode()
        }
        unmark()
        let string = text.string as NSString
        var location = 0
        for _ in 1..<max(line, 1) where location < string.length {
            location = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
        }
        text.setSelectedRange(NSRange(location: min(location, string.length), length: 0))
        light(string.lineRange(for: NSRange(location: min(location, string.length), length: 0)))
        // A pane that was just added has no size yet, so this waits for its first layout.
        DispatchQueue.main.async { [weak self] in
            guard let self, let layout = text.layoutManager, let container = text.textContainer else { return }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: min(location, string.length), length: 0),
                                           actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - 80)))
            scroll.reflectScrolledClipView(scroll.contentView)
            gutter.needsDisplay = true
        }
    }

    /// Marks what `find` finds in each line, as the search panel does. Line by line, so a regular expression's ^ and $ mean what they did there.
    func mark(_ find: (String) -> [Range<String.Index>]) {
        unmark()
        guard let layout = text.layoutManager, let colors = themeColors else { return }
        let color = colors.background.mixed(with: colors.foreground, 0.32)
        let string = text.string as NSString
        var found: [NSRange] = []
        // The lines are walked here and nowhere else, so `find` is only borrowed.
        withoutActuallyEscaping(find) { find in
            string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines]) { line, range, _, _ in
                guard let line else { return }
                found += find(line).map { NSRange(location: range.location + NSRange($0, in: line).location, length: NSRange($0, in: line).length) }
            }
        }
        for mark in found { layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: mark) }
        marks = found
    }

    private func unmark() {
        guard !marks.isEmpty else { return }
        let length = (text.string as NSString).length
        for mark in marks {
            text.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSIntersectionRange(mark, NSRange(location: 0, length: length)))
        }
        marks = []
        // The lit line shares the attribute, so it is laid back on.
        if let line = litLine { litLine = nil; light(line) }
    }

    /// A soft band behind the line, in the theme's colors, so the eye lands on it.
    private func light(_ line: NSRange) {
        unlight()
        guard let layout = text.layoutManager, line.length > 0, let colors = themeColors else { return }
        layout.addTemporaryAttribute(.backgroundColor, value: colors.background.mixed(with: colors.foreground, 0.16), forCharacterRange: line)
        litLine = line
    }

    private func unlight() {
        guard let line = litLine else { return }
        litLine = nil
        let length = (text.string as NSString).length
        text.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSIntersectionRange(line, NSRange(location: 0, length: length)))
    }

    /// Reads the file again. Keeping the position means an agent's edit doesn't throw you back to the top.
    private func load(keepingPosition: Bool) {
        let selection = text.selectedRange()
        let origin = scroll.contentView.bounds.origin
        switch Result(catching: { try Files.read(path) }) {
        case .success(.text(let string)):
            // A large file's on-screen colors would stay on whatever text comes next.
            text.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: text.textStorage?.length ?? 0))
            fitLayout(string)
            text.string = string
            onDisk = string
            // Go and Makefiles indent with tabs by rule, so a file too short to tell still gets them.
            let tabs = ["go", "mk"].contains((path as NSString).pathExtension) || (path as NSString).lastPathComponent == "Makefile"
            text.indentUnit = Typing.indentUnit(of: string as NSString, fallback: tabs ? "\t" : "    ")
            let kind = (path as NSString).pathExtension.lowercased()
            text.pairs = language != nil && !Markdown.handles(path)
            text.colonOpens = ["py", "yaml", "yml"].contains(kind)
            text.pairsApostrophes = kind != "rs"
            text.isEditable = true
            display(message: nil)
        case .success(.binary):
            display(message: "This file isn't text.")
        case .success(.tooLarge):
            display(message: "This file is too large to show here.")
        case .failure where !FileManager.default.fileExists(atPath: path):
            display(message: "This file was deleted.")
        case .failure(let error):
            display(message: error.localizedDescription)
        }
        isDirty = false
        conflict.isHidden = true
        needsLayout = true
        gutter.textChanged()
        highlight()
        loadBlame()
        // An agent's edit is a change too. Reading the base again also catches a commit made with it.
        if inCheckout { loadChangeBase() }
        // The server hears of the new text and answers with its problems. Until then, the last ones it gave are placed again.
        showProblems()
        links.textChanged()
        if keepingPosition {
            let length = (text.string as NSString).length
            text.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            text.scroll(.zero)
        }
    }

    /// Wraps a file with a very long line, and lays out only what is on screen in a large one.
    private func fitLayout(_ string: String) {
        fittedLength = string.utf16.count
        wraps = Files.hasLongLine(string)
        text.layoutManager?.allowsNonContiguousLayout = fittedLength > Self.large
    }

    var canFormat: Bool { (path as NSString).pathExtension.lowercased() == "json" && message.isHidden }

    var jsonProblem: String? { JSONFormat.problem(text.string) }

    /// An edit like any other, so ⌘Z takes it back and nothing is saved until you save.
    func reformatJSON(pretty: Bool) {
        guard let new = pretty ? JSONFormat.pretty(text.string) : JSONFormat.minified(text.string), new != text.string else { return }
        let all = NSRange(location: 0, length: (text.string as NSString).length)
        guard text.shouldChangeText(in: all, replacementString: new) else { return }
        text.textStorage?.replaceCharacters(in: all, with: new)
        text.didChangeText()
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func display(message text: String?) {
        if text != nil {
            onDisk = nil
            self.text.isEditable = false
        }
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        updateMode()
    }

    // MARK: Saving

    /// Writes in place rather than replacing the file, so its permissions, like a script's executable bit, stay.
    func save() throws {
        guard isDirty else { return }
        let string = text.string
        try Data(string.utf8).write(to: URL(fileURLWithPath: path))
        onDisk = string
        isDirty = false
        conflict.isHidden = true
        needsLayout = true
        loadBlame()
    }

    /// Runs `proceed` once unsaved edits are saved or thrown away. Asks first, and runs `cancelled` on Cancel.
    func confirmClose(_ proceed: @escaping () -> Void, cancelled: (() -> Void)? = nil) {
        guard isDirty, let window else { return proceed() }
        let alert = NSAlert()
        alert.messageText = "Save changes to \((path as NSString).lastPathComponent)?"
        alert.informativeText = "Your changes are lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                do {
                    try self.save()
                } catch {
                    cancelled?()
                    return NSAlert(error: error).beginSheetModal(for: window)
                }
            case .alertSecondButtonReturn:
                self.load(keepingPosition: true)
            default:
                cancelled?()
                return
            }
            // A sheet that follows, like closing a worktree, can only start once this one is gone.
            DispatchQueue.main.async(execute: proceed)
        }
    }

    // MARK: Changes on disk

    /// Agents often write a new file and rename it over the old one, so the watch starts again on the new file.
    private func watch() {
        watcher?.cancel()
        watcher = nil
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let replaced = !source.data.isDisjoint(with: [.delete, .rename])
            // Give the writer a moment to put the new file in place.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if replaced { self.watch() }
                self.changedOnDisk()
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        watcher = source
    }

    private func changedOnDisk() {
        let current = (try? Files.read(path)).flatMap { if case .text(let string) = $0 { string } else { nil } }
        guard current != onDisk else { return }
        if isDirty {
            conflict.isHidden = false
            needsLayout = true
        } else {
            load(keepingPosition: true)
        }
    }

    @objc private func reloadFromDisk() { load(keepingPosition: true) }

    /// Your next save overwrites what is on disk.
    @objc private func keepMine() {
        // Compare later edits against the file as it is now, so matching the old version still counts as a change.
        if case .text(let string)? = try? Files.read(path) { onDisk = string }
        conflict.isHidden = true
        needsLayout = true
    }

    // MARK: Appearance

    func apply(background: NSColor, foreground: NSColor) {
        layer?.backgroundColor = background.cgColor
        conflict.layer?.backgroundColor = background.mixed(with: foreground, 0.07).cgColor
        conflictText.textColor = foreground
        themeColors = (background, foreground)
        preview.apply(background: background, foreground: foreground, syntax: syntax)
        message.textColor = background.mixed(with: foreground, 0.55)
        scroll.backgroundColor = background
        CodeText.apply(to: text, background: background, foreground: foreground)
        plainColor = foreground
        highlight()
        gutter.colors = (background, background.mixed(with: foreground, 0.35), background.mixed(with: foreground, 0.8))
        text.currentLineColor = background.mixed(with: foreground, 0.045)
        text.matchColor = background.mixed(with: foreground, 0.14)
        blame.colors = (background, foreground)
    }

    // MARK: Syntax colors

    func highlight(with colors: SyntaxColors) {
        syntax = colors
        blame.hues = colors.hues
        highlight()
        if let themeColors { preview.apply(background: themeColors.background, foreground: themeColors.foreground, syntax: colors) }
    }

    /// Typing waits for a pause, so a burst of keys colors the file once.
    private func highlightSoon() {
        highlightGeneration += 1
        // Their places moved with the edit. The colors on screen stay until the new ones come.
        tokens = []
        pendingHighlight?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlight(inBackground: true) }
        pendingHighlight = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Colors go straight on the text storage, so they never enter the undo history.
    private func highlight(inBackground: Bool = false) {
        guard let storage = text.textStorage else { return }
        highlightGeneration += 1
        let large = isLarge
        tokens = []
        guard let language, inBackground || large else {
            return CodeText.highlight(storage, language, syntax, plain: plainColor)
        }
        let generation = highlightGeneration
        let length = storage.length
        // Bridging copies the storage's mutable string, so the other thread reads text no edit can change.
        let snapshot = storage.string
        DispatchQueue.global(qos: .userInitiated).async {
            let tokens = Syntax.tokens(in: snapshot, language)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == highlightGeneration, let storage = text.textStorage, storage.length == length else { return }
                if isLarge {
                    self.tokens = tokens
                    colorVisible()
                } else {
                    CodeText.color(storage, tokens, syntax, plain: plainColor)
                }
            }
        }
    }

    /// Colors the lines on screen of a large file, as drawing-only attributes, which never lay the text out again.
    private func colorVisible() {
        guard !tokens.isEmpty, let syntax, let layout = text.layoutManager, let container = text.textContainer else { return }
        let glyphs = layout.glyphRange(forBoundingRect: text.visibleRect, in: container)
        let range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        var low = 0, high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(tokens[mid].range) <= range.location { low = mid + 1 } else { high = mid }
        }
        for token in tokens[low...] {
            guard token.range.location < NSMaxRange(range) else { break }
            layout.addTemporaryAttribute(.foregroundColor, value: syntax.color(token.kind), forCharacterRange: token.range)
        }
    }

    /// ⌘F, ⌘G and ⌘E use the text view's own find bar while the file has focus.
    func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    /// A divider beside the pane is being dragged. Wrapped text and the Markdown preview wait for it to stop before fitting the new width.
    /// Wrapping a whole file again on every point of a drag froze it.
    var resizing = false {
        didSet { if !resizing { needsLayout = true } }
    }
    private var deferringWrap: Bool { resizing || inLiveResize }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let bar = conflict.isHidden ? 0 : Self.barHeight
        conflict.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bar)
        keepButton.sizeToFit()
        reloadButton.sizeToFit()
        keepButton.frame.origin = NSPoint(x: bounds.width - keepButton.frame.width - 10, y: (bar - keepButton.frame.height) / 2)
        reloadButton.frame.origin = NSPoint(x: keepButton.frame.minX - reloadButton.frame.width - 6, y: keepButton.frame.minY)
        conflictText.frame = NSRect(x: 12, y: (bar - 16) / 2, width: max(0, reloadButton.frame.minX - 20), height: 16)
        let body = max(0, bounds.height - bar)
        blame.style = BlameColumn.Style(pane: bounds.width)
        let blameWidth = showsBlame ? blame.style.width : 0
        blame.frame = NSRect(x: 0, y: bar, width: blameWidth, height: body)
        gutter.frame = NSRect(x: blameWidth, y: bar, width: gutter.width, height: body)
        let start = blameWidth + gutter.width
        scroll.frame = NSRect(x: start, y: bar, width: max(0, bounds.width - start), height: body)
        // While a drag goes on, the preview keeps its width, and only its height follows.
        let previewWidth = deferringWrap && preview.frame.width > 0 ? preview.frame.width : bounds.width
        preview.frame = NSRect(x: 0, y: bar, width: previewWidth, height: body)
        // At least as big as the visible area, so short files still fill it and clicks land in the text.
        text.minSize = scroll.contentSize
        // Only on a new width: each resize measures the whole wrapped file again.
        if wraps, !deferringWrap, text.frame.width != scroll.contentSize.width { text.setFrameSize(NSSize(width: scroll.contentSize.width, height: text.frame.height)) }
        message.frame = NSRect(x: 12, y: bounds.midY - 10, width: max(0, bounds.width - 24), height: 20)
    }
}

private final class CodeTextView: NSTextView {
    var onFocus: (() -> Void)?

    // MARK: The cursor's line

    /// A faint band across the pane on the cursor's line, so your place is easy to find. Not while text is selected.
    var currentLineColor: NSColor? { didSet { needsDisplay = true } }
    /// Its top and height, with no width: the band is as wide as the view when drawn, so a resize needs nothing.
    private var currentLine: NSRect?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawProblems(in: rect)
        drawMatches(in: rect)
        guard let color = currentLineColor, let line = currentLine else { return }
        let band = NSRect(x: 0, y: line.minY, width: bounds.width, height: line.height)
        guard band.intersects(rect) else { return }
        color.setFill()
        band.fill()
    }

    // MARK: The bracket that matches, and the selected word elsewhere

    /// Behind the other places the selected word is. The matching bracket gets a frame in it.
    var matchColor: NSColor? { didSet { needsDisplay = true } }
    private var bracket: (NSRange, NSRange)?
    private var occurrences: [NSRange] = []
    /// Past this, a file is too big to search on every double-click.
    private static let occurrenceLimit = 1_000_000

    private func findMatches() {
        let selection = selectedRange()
        let newBracket = selection.length == 0 ? Typing.matchingBracket(text, at: selection.location) : nil
        let newOccurrences = wordOccurrences(of: selection)
        guard newBracket?.0 != bracket?.0 || newBracket?.1 != bracket?.1 || newOccurrences != occurrences else { return }
        bracket = newBracket
        occurrences = newOccurrences
        needsDisplay = true
    }

    /// The selection's other places, when it is one whole word, as a double-click makes it. At most a few hundred, since more is noise.
    private func wordOccurrences(of selection: NSRange) -> [NSRange] {
        guard (2...100).contains(selection.length), text.length < Self.occurrenceLimit else { return [] }
        let word = text.substring(with: selection)
        guard word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              let pattern = try? NSRegularExpression(pattern: "(?<![\\w])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\w])") else { return [] }
        let found = pattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)).prefix(500).map(\.range)
        return found.count > 1 ? found.filter { $0 != selection } : []
    }

    private func drawMatches(in dirty: NSRect) {
        guard let color = matchColor, bracket != nil || !occurrences.isEmpty else { return }
        color.setFill()
        for range in occurrences {
            guard let rect = rect(of: range), rect.intersects(dirty) else { continue }
            NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0), xRadius: 2, yRadius: 2).fill()
        }
        guard let bracket else { return }
        for range in [bracket.0, bracket.1] {
            guard let rect = rect(of: range), rect.intersects(dirty) else { continue }
            NSBezierPath(roundedRect: rect.insetBy(dx: -0.5, dy: 0), xRadius: 2, yRadius: 2).fill()
        }
    }

    // MARK: Problems

    struct Problem {
        var range: NSRange
        let color: NSColor
        let diagnostic: LSP.Diagnostic
    }

    /// Sorted by where they start. Drawn as squiggles under the text, only where the view is drawing.
    var problems: [Problem] = [] { didSet { needsDisplay = true } }
    /// The character under the mouse, or nil when it leaves, for the problem there to say what's wrong.
    var onMouseOver: ((Int?) -> Void)?

    /// Problems after an edit move with it. One the edit touched is dropped, since its words changed, until the server says again.
    func shiftProblems(after edited: NSRange, by delta: Int) {
        guard !problems.isEmpty else { return }
        let start = edited.location, oldEnd = NSMaxRange(edited) - delta
        problems = problems.compactMap { problem in
            var problem = problem
            if NSMaxRange(problem.range) <= start { return problem }
            if problem.range.location >= oldEnd {
                problem.range.location += delta
                return problem
            }
            return nil
        }
    }

    private func drawProblems(in dirty: NSRect) {
        guard !problems.isEmpty, let layout = layoutManager, let container = textContainer else { return }
        let length = (string as NSString).length
        let visible = layout.characterRange(forGlyphRange: layout.glyphRange(forBoundingRect: dirty, in: container), actualGlyphRange: nil)
        for problem in problems where NSMaxRange(problem.range) <= length && NSIntersectionRange(problem.range, visible).length > 0 {
            let glyphs = layout.glyphRange(forCharacterRange: problem.range, actualCharacterRange: nil)
            problem.color.setStroke()
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { [textContainerOrigin] rect, _ in
                let line = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                Self.squiggle(from: line.minX, to: line.maxX, at: line.maxY - 1).stroke()
            }
        }
    }

    /// A wave under the words, two points tall, as editors mark what's wrong.
    private static func squiggle(from start: CGFloat, to end: CGFloat, at y: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 1
        var x = start, up = true
        path.move(to: NSPoint(x: x, y: y))
        while x < end {
            x = min(x + 2, end)
            path.line(to: NSPoint(x: x, y: up ? y - 2 : y))
            up.toggle()
        }
        return path
    }

    /// Where characters are drawn, in this view's coordinates.
    func rect(of range: NSRange) -> NSRect? {
        guard let layout = layoutManager, let container = textContainer, NSMaxRange(range) <= (string as NSString).length else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { findMatches() }
        // Only the old and new lines are drawn again, not the whole pane.
        let old = currentLine
        currentLine = cursorLine()
        guard old != currentLine else { return }
        for line in [old, currentLine].compactMap({ $0 }) {
            setNeedsDisplay(NSRect(x: 0, y: line.minY, width: bounds.width, height: line.height))
        }
    }

    private func cursorLine() -> NSRect? {
        guard selectedRange().length == 0, let layout = layoutManager else { return nil }
        let length = (string as NSString).length
        let location = selectedRange().location
        // After a final line break the cursor sits on a line with no characters, which only the extra fragment describes.
        let fragment = location >= length && (length == 0 || (string as NSString).character(at: length - 1) == 0x0A)
            ? layout.extraLineFragmentRect
            : layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: min(location, max(length - 1, 0))), effectiveRange: nil)
        guard fragment.height > 0 else { return nil }
        return NSRect(x: 0, y: fragment.minY + textContainerOrigin.y, width: 0, height: fragment.height)
    }

    // MARK: ⌘ over a name, for go to definition and references

    /// Whether ⌘ over a name means anything, which is only with language servers on. Off, ⌘-click is the text view's own.
    var commandLinks: () -> Bool = { false }
    /// A ⌘-click, with the character it landed on, which a click would otherwise only select.
    var onCommandClick: ((Int) -> Void)?
    /// The character under the mouse while ⌘ is held, or nil when it isn't or the mouse is elsewhere.
    var onCommandHover: ((Int?) -> Void)?
    /// Where the name that would open is drawn, so the pointer can be a hand over it.
    var linkRect: NSRect? {
        didSet { pointAtLink() }
    }
    private var tracking: NSTrackingArea?
    private var flagsMonitor: Any?

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), event.clickCount == 1, commandLinks(),
              let index = character(at: convert(event.locationInWindow, from: nil)) else {
            return super.mouseDown(with: event)
        }
        // The click first, while the answer found on hover is still kept.
        onCommandClick?(index)
        onCommandHover?(nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover(holding: event.modifierFlags)
        if linkRect != nil { pointAtLink() }
        // Only over a character itself, not the empty space past the end of its line.
        let point = convert(event.locationInWindow, from: nil)
        let index = character(at: point).flatMap { rect(of: NSRange(location: $0, length: 1))?.insetBy(dx: 0, dy: -1).contains(point) == true ? $0 : nil }
        onMouseOver?(index)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onCommandHover?(nil)
        onMouseOver?(nil)
    }

    /// The text under the mouse moves, so the name lit is another one.
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        hover(holding: NSEvent.modifierFlags)
        onMouseOver?(nil)
    }

    /// Pressing or letting go of ⌘ with the mouse still is a change too.
    /// flagsChanged reaches only the focused view, so the pane watches the window's events, as a terminal usually has the focus.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        guard window != nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if event.window === self?.window { self?.hover(holding: event.modifierFlags) }
            return event
        }
    }

    private func hover(holding flags: NSEvent.ModifierFlags) {
        guard commandLinks() else { return }
        guard flags.contains(.command), let window else { return onCommandHover?(nil) ?? () }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        // Only what is on screen, since the text runs on above and below the pane.
        onCommandHover?(visibleRect.contains(point) ? character(at: point) : nil)
    }

    private func character(at point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer, bounds.contains(point) else { return nil }
        let inside = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        return layout.characterIndex(for: inside, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
    }

    /// A text view puts its I-beam back on every move, over any cursor rect, so the hand is set after it.
    /// Also when the answer arrives with the mouse still.
    private func pointAtLink() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if let linkRect, linkRect.contains(point) {
            NSCursor.pointingHand.set()
        } else if visibleRect.contains(point) {
            NSCursor.iBeam.set()
        }
    }

    // MARK: Menus
    /// Items before the text's own, for what a right-click in code is most often for.
    var leadingMenuItems: (() -> [NSMenuItem])?
    /// Items after the text's own, like git blame, where a right-click in the code finds them.
    var extraMenuItems: (() -> [NSMenuItem])?

    /// The line commands under Paste, each showing its keys so they're learned from the menu. Only shown, since a right-click menu's keys never fire.
    private func linesMenu() -> NSMenuItem {
        let lines = NSMenu()
        func add(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags, _ run: @escaping () -> Void) {
            let item = ActionMenuItem(title: title, handler: run)
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers
            lines.addItem(item)
        }
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!), down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        add("Move Line Up", up, .option) { [weak self] in self?.moveLines(up: true) }
        add("Move Line Down", down, .option) { [weak self] in self?.moveLines(up: false) }
        add("Copy Line Up", up, [.option, .shift]) { [weak self] in self?.copyLines(up: true) }
        add("Copy Line Down", down, [.option, .shift]) { [weak self] in self?.copyLines(up: false) }
        add("Delete Line", "k", [.command, .shift]) { [weak self] in self?.deleteLines() }
        if comment != nil {
            lines.addItem(.separator())
            add("Toggle Comment", "/", .command) { [weak self] in self?.toggleComment() }
        }
        let item = NSMenuItem(title: "Lines", action: nil, keyEquivalent: "")
        item.submenu = lines
        return item
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if isEditable {
            let paste = menu.items.firstIndex { $0.action == #selector(paste(_:)) }
            menu.insertItem(linesMenu(), at: paste.map { $0 + 1 } ?? menu.items.count)
        }
        let leading = leadingMenuItems?() ?? []
        if !leading.isEmpty {
            menu.insertItem(.separator(), at: 0)
            leading.reversed().forEach { menu.insertItem($0, at: 0) }
        }
        let extra = extraMenuItems?() ?? []
        if !extra.isEmpty {
            menu.addItem(.separator())
            extra.forEach(menu.addItem)
        }
        return menu
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    // MARK: Line commands, on VS Code's keys

    /// What ⌘/ puts around a line, from the file's language. Nil where Farol doesn't know one.
    var comment: LineEditing.Comment?

    private var text: NSString { textStorage?.mutableString ?? "" }

    private func apply(_ edit: LineEditing.Edit?) {
        guard isEditable, let edit, shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }

    func moveLines(up: Bool) { apply(LineEditing.move(text, selectedRange(), up: up)) }
    func copyLines(up: Bool) { apply(LineEditing.duplicate(text, selectedRange(), up: up)) }
    func deleteLines() { apply(LineEditing.delete(text, selectedRange())) }
    func toggleComment() { if let comment { apply(LineEditing.toggleComment(text, selectedRange(), comment)) } }

    /// ⌥↑ and ⌥↓ move lines, with ⇧ they copy them. A Mac text view would jump to a paragraph's ends, which code rarely needs.
    override func keyDown(with event: NSEvent) {
        // Typing means the eyes are on the cursor, so a card under the mouse goes.
        onMouseOver?(nil)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let up = event.keyCode == 126
        guard event.keyCode == 125 || up, flags == .option || flags == [.option, .shift] else { return super.keyDown(with: event) }
        flags.contains(.shift) ? copyLines(up: up) : moveLines(up: up)
    }

    /// ⌘/ comments lines, matched by the character so it works on any keyboard where / takes ⇧. ⇧⌘K deletes them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == "/", flags.subtracting(.shift) == .command {
            toggleComment()
            return true
        }
        if key == "k", flags == [.command, .shift] {
            deleteLines()
            return true
        }
        // ⌘] and ⌘[ move the lines in and out, as in Xcode and VS Code. Matched by the character, which needs ⌥ on some keyboards.
        if key == "]" || key == "[", flags.subtracting(.option) == .command {
            indentLines(key == "[")
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// A text view turns Cut and Copy off with nothing selected, and a menu item that's off never gets its ⌘X or ⌘C.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        takesLine(item.action) ?? super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        takesLine(item.action) ?? super.validateMenuItem(item)
    }

    /// Whether Cut or Copy can take the cursor's line, or nil for anything else.
    private func takesLine(_ action: Selector?) -> Bool? {
        guard selectedRange().length == 0, action == #selector(cut(_:)) || action == #selector(copy(_:)) else { return nil }
        return text.length > 0 && (isEditable || action == #selector(copy(_:)))
    }

    /// With nothing selected, ⌘X and ⌘C take the whole line.
    override func cut(_ sender: Any?) {
        if selectedRange().length == 0 { setSelectedRange(LineEditing.lines(text, selectedRange())) }
        super.cut(sender)
    }

    override func copy(_ sender: Any?) {
        guard selectedRange().length == 0 else { return super.copy(sender) }
        var line = text.substring(with: LineEditing.lines(text, selectedRange()))
        guard !line.isEmpty else { return }
        if !line.hasSuffix("\n") { line += "\n" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }

    // MARK: Typing, as code editors do

    /// The file's own indent, a tab or some spaces, which Tab, Return and Backspace follow.
    var indentUnit = "    "
    /// Brackets and quotes pair up in code. In prose, like Markdown or plain text, they'd get in the way.
    var pairs = true
    /// A colon starts a block in Python and YAML, so Return after one adds a level.
    var colonOpens = false
    /// Rust writes lifetimes like `&'a`, where a paired quote would be in the way.
    var pairsApostrophes = true

    /// Return keeps the indent, adds a level after an opener, and opens `{}` onto its own lines.
    override func insertNewline(_ sender: Any?) {
        apply(Typing.newline(text, selectedRange(), unit: indentUnit, colonOpens: colonOpens))
    }

    /// Tab indents, in the file's style, and over several lines moves them all.
    override func insertTab(_ sender: Any?) {
        apply(Typing.indent(text, selectedRange(), unit: indentUnit))
    }

    override func insertBacktab(_ sender: Any?) {
        apply(Typing.outdent(text, selectedRange(), unit: indentUnit))
    }

    func indentLines(_ out: Bool) {
        apply(out ? Typing.outdent(text, selectedRange(), unit: indentUnit) : Typing.indentLines(text, selectedRange(), unit: indentUnit))
    }

    /// Brackets and quotes come in pairs. Not while an input method composes, like a dead key for an accent.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if pairs, let typed = string as? String, typed.count == 1, !hasMarkedText(), replacementRange.location == NSNotFound,
           typed != "'" || pairsApostrophes,
           let edit = Typing.type(typed, text, selectedRange()) {
            return apply(edit)
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Backspace takes an empty pair whole, and an indent a level at a time.
    override func deleteBackward(_ sender: Any?) {
        if pairs, let edit = Typing.deleteBackward(text, selectedRange(), unit: indentUnit) { return apply(edit) }
        super.deleteBackward(sender)
    }
}

/// The gutter left of the text, a plain view beside the scroll view so the text can never slide under it.
/// Only the lines on screen are drawn, so long files stay cheap.
private final class LineNumbers: NSView {
    var contextMenu: (() -> NSMenu?)?
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private weak var textView: NSTextView?
    /// Where each line starts, so the first visible line is a binary search away.
    private var lines = LineStarts()
    private(set) var width: CGFloat = 0
    var onResize: (() -> Void)?
    /// `current` is the cursor's line number, brighter so your place is easy to find.
    var colors = (background: NSColor.black, text: NSColor.gray, current: NSColor.white) { didSet { needsDisplay = true } }
    /// Lines changed since the last commit, as a bar at the gutter's edge: added, modified, and a wedge where lines were deleted.
    var marks: [LineChanges.Mark] = [] {
        didSet {
            guard marks != oldValue else { return }
            byLine = Dictionary(marks.map { ($0.line, $0.kind) }, uniquingKeysWith: { first, _ in first })
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private var byLine: [Int: LineChanges.Kind] = [:]
    var markColors: () -> (added: NSColor, modified: NSColor, deleted: NSColor)? = { nil }
    var onClickMark: (() -> Void)?
    private static let markWidth: CGFloat = 3
    /// Where the marks are drawn, and a click on them lands: the gutter's right edge, beside the text.
    private var markStrip: NSRect { NSRect(x: width - Self.markWidth - 2, y: 0, width: Self.markWidth + 2, height: bounds.height) }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        clipsToBounds = true
        // The storage says what changed, which the text view's own notice doesn't.
        NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: textView.textStorage, queue: nil) { [weak self] note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                self?.lines.edit(storage.editedRange, changeInLength: storage.changeInLength, in: storage.mutableString)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    /// The lines are already counted as the storage changed. This fits the width to their count and draws them again.
    func textChanged() {
        let digits = String(repeating: "8", count: max(3, String(lines.starts.count).count)) as NSString
        let width = (digits.size(withAttributes: [.font: Self.font]).width + 20).rounded()
        if width != self.width {
            self.width = width
            onResize?()
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        colors.background.setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: colors.text]
        var current = attributes
        current[.foregroundColor] = colors.current
        let cursor = textView.map { lines.line(atOrBefore: $0.selectedRange().location) }
        let tints = byLine.isEmpty ? nil : markColors()
        forEachVisibleLine { line, top, height in
            let label = "\(line + 1)" as NSString
            let style = line == cursor ? current : attributes
            let size = label.size(withAttributes: style)
            label.draw(at: NSPoint(x: width - size.width - 10, y: top + (height - size.height) / 2), withAttributes: style)
            guard let tints else { return }
            drawMark(byLine[line], top: top, height: height, tints)
            // Lines deleted from the end leave their wedge under the last line.
            if line == lines.starts.count - 1, byLine[lines.starts.count] == .deleted { drawMark(.deleted, top: top + height, height: 0, tints) }
        }
    }

    private func drawMark(_ kind: LineChanges.Kind?, top: CGFloat, height: CGFloat, _ tints: (added: NSColor, modified: NSColor, deleted: NSColor)) {
        let x = width - Self.markWidth - 2
        switch kind {
        case .added, .modified:
            (kind == .added ? tints.added : tints.modified).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: top, width: Self.markWidth, height: height), xRadius: 1, yRadius: 1).fill()
        case .deleted:
            // A wedge pointing at the gap the lines left, between this line and the one above.
            tints.deleted.setFill()
            let wedge = NSBezierPath()
            wedge.move(to: NSPoint(x: x, y: top - 4))
            wedge.line(to: NSPoint(x: x + 5, y: top))
            wedge.line(to: NSPoint(x: x, y: top + 4))
            wedge.close()
            wedge.fill()
        case nil:
            break
        }
    }

    /// A click on a mark opens the changes. Anywhere else in the gutter picks the pane, as before.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard markStrip.contains(point), let line = line(at: point.y), byLine[line] != nil || byLine[line + 1] == .deleted else {
            return super.mouseDown(with: event)
        }
        onClickMark?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !byLine.isEmpty { addCursorRect(markStrip, cursor: .pointingHand) }
    }

    private func line(at y: CGFloat) -> Int? {
        var found: Int?
        forEachVisibleLine { line, top, height in if y >= top, y < top + height { found = line } }
        return found
    }

    /// The lines on screen, each with its top and height in this view's own coordinates.
    func forEachVisibleLine(_ body: (_ line: Int, _ top: CGFloat, _ height: CGFloat) -> Void) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer,
              !textView.string.isEmpty else { return }
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = lines.line(atOrBefore: characters.location)
        while line < lines.starts.count, lines.starts[line] <= NSMaxRange(characters) {
            let glyph = layout.glyphIndexForCharacter(at: lines.starts[line])
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            // Text view coordinates, shifted by how far it is scrolled. Both views start at the same height.
            body(line, fragment.minY + textView.textContainerOrigin.y - visible.minY, fragment.height)
            line += 1
        }
    }

    var count: Int { lines.starts.count }

    /// Where a line starts, from 0.
    func start(ofLine line: Int) -> Int { lines.starts[min(max(line, 0), lines.starts.count - 1)] }

    /// The line holding `location`, from 0, and where it starts.
    func line(containing location: Int) -> (index: Int, start: Int) {
        let index = lines.line(atOrBefore: location)
        return (index, lines.starts[index])
    }
}

/// Who last changed each line and when, left of the numbers, on every line so it reads as one steady column.
/// Each commit's hash has its own color, which shows where a group starts and ends. A click opens the commit in the git graph.
private final class BlameColumn: NSView {
    /// Names only show when there's room for them whole, since cut names are what makes a column look messy.
    enum Style {
        case full, normal, narrow

        init(pane: CGFloat) { self = pane >= 560 ? .full : pane >= 300 ? .normal : .narrow }

        var width: CGFloat {
            switch self {
            case .full: 232
            case .normal: 96
            case .narrow: 62
            }
        }
    }

    private static let hashFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let textFont = NSFont.systemFont(ofSize: 11)
    private static let inset: CGFloat = 8
    private static let hashWidth: CGFloat = 48

    private unowned let gutter: LineNumbers
    private var hoverArea: NSTrackingArea?
    private var hovered: String? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var order: [String: Int] = [:]
    var lines: [Blame.Line] = [] {
        didSet {
            guard lines != oldValue else { return }
            hovered = nil
            // In the order they appear, since a color picked from the hash can give two neighbors the same one.
            order = [:]
            for line in lines where order[line.hash] == nil { order[line.hash] = order.count }
            needsDisplay = true
        }
    }
    var style = Style.normal { didSet { if style != oldValue { needsDisplay = true } } }
    var colors = (background: NSColor.black, foreground: NSColor.white) { didSet { needsDisplay = true } }
    var hues: [NSColor] = [] { didSet { needsDisplay = true } }
    var onShowCommit: ((String) -> Void)?
    var contextMenu: ((Blame.Line?) -> NSMenu?)?

    init(gutter: LineNumbers) {
        self.gutter = gutter
        super.init(frame: .zero)
        clipsToBounds = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        colors.background.setFill()
        bounds.fill()
        gutter.forEachVisibleLine { line, top, height in
            if lines.indices.contains(line) { draw(lines[line], top: top, height: height) }
        }
    }

    private func draw(_ entry: Blame.Line, top: CGFloat, height: CGFloat) {
        let lit = entry.hash == hovered
        let text = colors.background.mixed(with: colors.foreground, lit ? 0.85 : 0.45)
        func label(_ string: String, font: NSFont, color: NSColor, x: CGFloat, width: CGFloat, right: Bool = false) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.alignment = right ? .right : .left
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            let lineHeight = (string as NSString).size(withAttributes: attributes).height
            (string as NSString).draw(in: NSRect(x: x, y: top + (height - lineHeight) / 2, width: width, height: lineHeight), withAttributes: attributes)
        }
        guard entry.isCommitted else {
            return label(style == .full ? "Not committed" : "new", font: Self.textFont, color: text, x: Self.inset, width: bounds.width - 2 * Self.inset)
        }
        let hue = color(for: entry.hash)
        label(entry.shortHash, font: Self.hashFont, color: lit ? hue : colors.background.mixed(with: hue, 0.75), x: Self.inset, width: Self.hashWidth)
        let ageWidth: CGFloat = 28
        if style != .narrow {
            label(Blame.age(of: entry.date), font: Self.textFont, color: text, x: bounds.width - Self.inset - ageWidth, width: ageWidth, right: true)
        }
        if style == .full {
            let x = Self.inset + Self.hashWidth + 8
            label(entry.author, font: Self.textFont, color: text, x: x, width: bounds.width - x - Self.inset - ageWidth - 6)
        }
    }

    private func color(for hash: String) -> NSColor {
        guard !hues.isEmpty, let index = order[hash] else { return colors.foreground }
        return hues[index % hues.count]
    }

    /// Who, what and when, in the order Zed's card has them.
    private func card(for line: Blame.Line) -> NSAttributedString {
        let muted = colors.background.mixed(with: colors.foreground, 0.55)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4
        func part(_ text: String, _ color: NSColor, weight: NSFont.Weight = .regular) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph])
        }
        let result = NSMutableAttributedString()
        guard line.isCommitted else {
            result.append(part("Not committed yet", colors.foreground))
            return result
        }
        result.append(part(line.author, colors.foreground, weight: .medium))
        if !line.email.isEmpty { result.append(part("  <\(line.email)>", muted)) }
        result.append(part("\n\(line.summary)\n", colors.foreground))
        result.append(part("\(line.date.formatted(date: .abbreviated, time: .omitted))  \(line.shortHash)", muted))
        return result
    }

    private func entry(at point: NSPoint) -> Blame.Line? {
        var found: Blame.Line?
        gutter.forEachVisibleLine { line, top, height in
            if point.y >= top, point.y < top + height, lines.indices.contains(line) { found = lines[line] }
        }
        return found
    }

    /// Replaces only our own area. Removing every area also drops the ones AppKit adds for itself.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let under = entry(at: point)
        (under?.isCommitted == true ? NSCursor.pointingHand : NSCursor.arrow).set()
        guard under?.hash != hovered else { return }
        hovered = under?.hash
        HoverTip.shared.hide()
        guard let under, let window else { return }
        // Just under the mouse, so the card covers as little of the code as it can.
        let anchor = NSRect(x: point.x, y: point.y + 8, width: 0, height: 0)
        HoverTip.shared.show(card: card(for: under), below: window.convertToScreen(convert(anchor, to: nil)), in: window)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        HoverTip.shared.hide()
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        if let line = entry(at: convert(event.locationInWindow, from: nil)), line.isCommitted {
            onShowCommit?(line.hash)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?(entry(at: convert(event.locationInWindow, from: nil)))
    }
}
