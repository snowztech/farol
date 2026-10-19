import AppKit
import FarolCore

/// A pane that shows a file: a header with its name, then the text with line numbers.
/// Edits are saved with ⌘S. When an agent changes the file on disk, it reloads, or asks if you have unsaved edits.
final class FileView: NSView {
    private static let headerHeight: CGFloat = 26
    private static let barHeight: CGFloat = 30

    private(set) var path = ""
    /// The file's folder inside its checkout, like "internal/config/", shown muted before the name.
    private var folder = ""
    private var titleColors = (name: NSColor.labelColor, folder: NSColor.secondaryLabelColor)
    private var language: Syntax.Language?
    private var syntax: SyntaxColors?
    private var plainColor = NSColor.textColor
    private var pendingHighlight: DispatchWorkItem?
    /// Coloring reruns on the whole file, so very large files stay plain. Coloring only the edited lines would lift the limit.
    private static let highlightLimit = 400_000
    private(set) var isDirty = false {
        didSet {
            unsavedDot.isHidden = !isDirty
            needsLayout = true
        }
    }
    var onFocus: (() -> Void)?
    var onClose: (() -> Void)?
    /// Opens another file in this pane, from a link in the Markdown preview.
    var onOpenFile: ((String) -> Void)?

    /// The file as last read or saved, to tell our own save from someone else's change.
    private var onDisk: String?
    private var watcher: DispatchSourceFileSystemObject?

    private let header = NSView()
    private let title = NSTextField(labelWithString: "")
    /// Same size as the sidebar's status dots, but muted, since colored dots mean agent states.
    private let unsavedDot = NSView()
    private static let dotSize: CGFloat = 7
    private lazy var closeButton = QuietButton(symbol: "xmark", help: "Close file (⌘W)") { [weak self] in self?.onClose?() }
    private lazy var previewButton = QuietButton(symbol: "eye", help: "Preview") { [weak self] in self?.togglePreview() }
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
        super.init(frame: .zero)
        wantsLayer = true

        title.font = .systemFont(ofSize: 12, weight: .medium)
        // A narrow pane drops the start of the folder first, so the name stays readable.
        title.lineBreakMode = .byTruncatingHead
        header.wantsLayer = true
        header.addSubview(title)
        unsavedDot.wantsLayer = true
        unsavedDot.layer?.cornerRadius = Self.dotSize / 2
        unsavedDot.isHidden = true
        unsavedDot.toolTip = "Unsaved changes (⌘S to save)"
        header.addSubview(unsavedDot)
        header.addSubview(closeButton)
        header.addSubview(previewButton)

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
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: text, queue: .main) { [weak self] _ in
            guard let self else { return }
            // Typing a line and deleting it again leaves nothing to save.
            isDirty = text.string != onDisk
            unmark()
            gutter.textChanged()
            highlightSoon()
        }

        NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: text, queue: .main) { [weak self] _ in
            guard let self, let line = litLine, !NSLocationInRange(text.selectedRange().location, line) else { return }
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
        ) { [weak self] _ in self?.gutter.needsDisplay = true }

        message.alignment = .center
        message.isHidden = true

        preview.text.onFocus = { [weak self] in self?.onFocus?() }
        preview.onOpenFile = { [weak self] in self?.onOpenFile?($0) }

        gutter.onResize = { [weak self] in self?.needsLayout = true }
        for view in [header, conflict, gutter, scroll, preview, message] { addSubview(view) }
        show(path)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { watcher?.cancel() }

    override var isFlipped: Bool { true }

    /// The text that takes the keyboard: the preview while it shows, else the source.
    var textView: NSTextView { showsPreview ? preview.text : text }

    /// The text selected in what the pane shows, or nil without a selection.
    var selectedText: String? {
        let range = textView.selectedRange()
        return range.length > 0 ? (textView.string as NSString).substring(with: range) : nil
    }

    /// A click on the header or the line numbers picks this pane too, so ⌘W closes the file and not a terminal.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }

    // MARK: Markdown preview

    private var showsPreview: Bool { Markdown.handles(path) && previewing && message.isHidden }

    private func togglePreview() {
        let focused = window?.firstResponder === textView
        previewing.toggle()
        UserDefaults.standard.set(previewing, forKey: Self.previewKey)
        updateMode()
        if focused { window?.makeFirstResponder(textView) }
    }

    /// Shows the source or the preview. The preview reads the text being edited, so unsaved edits show too.
    private func updateMode() {
        let markdown = Markdown.handles(path)
        previewButton.isHidden = !markdown
        previewButton.show(symbol: previewing ? "chevron.left.forwardslash.chevron.right" : "eye",
                           help: previewing ? "Show the source" : "Preview")
        preview.isHidden = !showsPreview
        scroll.isHidden = !message.isHidden || showsPreview
        gutter.isHidden = scroll.isHidden
        if showsPreview { preview.show(text.string, path: path) }
        needsLayout = true
    }

    /// Loads another file into the same pane. Callers check `isDirty` first, see confirmClose.
    func show(_ path: String) {
        self.path = path
        // Read for each file, so a choice made in another pane holds here too.
        previewing = UserDefaults.standard.bool(forKey: Self.previewKey)
        folder = ""
        language = Syntax.language(for: path)
        updateTitle()
        title.toolTip = (path as NSString).abbreviatingWithTildeInPath
        load(keepingPosition: false)
        watch()
        findFolder()
    }

    /// Asks git where the checkout starts, off the main thread. Outside a checkout the header shows only the name.
    private func findFolder() {
        let path = path
        let directory = (path as NSString).deletingLastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            let top = Git.topLevel(of: directory)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.path == path, let top, directory.hasPrefix(top + "/") else { return }
                self.folder = String(directory.dropFirst(top.count + 1)) + "/"
                self.updateTitle()
            }
        }
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
            text.string = string
            onDisk = string
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
        if keepingPosition {
            let length = (text.string as NSString).length
            text.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            text.scroll(.zero)
        }
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

    private func updateTitle() {
        let font = title.font ?? .systemFont(ofSize: 12)
        let name = (path as NSString).lastPathComponent
        let result = NSMutableAttributedString(string: folder, attributes: [.font: font, .foregroundColor: titleColors.folder])
        result.append(NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: titleColors.name]))
        title.attributedStringValue = result
        needsLayout = true
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
        // Same color as the text below, so the header reads as a row of the pane, not a bar on top of it.
        header.layer?.backgroundColor = background.cgColor
        conflict.layer?.backgroundColor = background.mixed(with: foreground, 0.07).cgColor
        conflictText.textColor = foreground
        titleColors = (background.mixed(with: foreground, 0.75), background.mixed(with: foreground, 0.45))
        unsavedDot.layer?.backgroundColor = background.mixed(with: foreground, 0.55).cgColor
        updateTitle()
        closeButton.apply(background: background, foreground: foreground)
        previewButton.apply(background: background, foreground: foreground)
        themeColors = (background, foreground)
        preview.apply(background: background, foreground: foreground, syntax: syntax)
        message.textColor = background.mixed(with: foreground, 0.55)
        scroll.backgroundColor = background
        CodeText.apply(to: text, background: background, foreground: foreground)
        plainColor = foreground
        highlight()
        gutter.colors = (background, background.mixed(with: foreground, 0.35))
    }

    // MARK: Syntax colors

    func highlight(with colors: SyntaxColors) {
        syntax = colors
        highlight()
        if let themeColors { preview.apply(background: themeColors.background, foreground: themeColors.foreground, syntax: colors) }
    }

    /// Typing waits for a pause, so a burst of keys colors the file once.
    private func highlightSoon() {
        pendingHighlight?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlight() }
        pendingHighlight = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Colors go straight on the text storage, so they never enter the undo history.
    private func highlight() {
        guard let storage = text.textStorage else { return }
        let small = storage.length <= Self.highlightLimit
        CodeText.highlight(storage, small ? language : nil, syntax, plain: plainColor)
    }

    /// ⌘F, ⌘G and ⌘E use the text view's own find bar while the file has focus.
    func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    override func layout() {
        super.layout()
        let h = Self.headerHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        closeButton.frame = NSRect(x: bounds.width - 28, y: 3, width: 20, height: 20)
        previewButton.frame = NSRect(x: bounds.width - 52, y: 3, width: 20, height: 20)
        // The dot follows the name, and the name gives up room first when the pane is narrow.
        let room = max(0, bounds.width - 48 - Self.dotSize - 8 - (previewButton.isHidden ? 0 : 24))
        let titleWidth = min(ceil(title.attributedStringValue.size().width) + 4, room)
        title.frame = NSRect(x: 12, y: 5, width: titleWidth, height: 16)
        unsavedDot.frame = NSRect(x: title.frame.maxX + 4, y: (h - Self.dotSize) / 2, width: Self.dotSize, height: Self.dotSize)
        let bar = conflict.isHidden ? 0 : Self.barHeight
        conflict.frame = NSRect(x: 0, y: h, width: bounds.width, height: bar)
        keepButton.sizeToFit()
        reloadButton.sizeToFit()
        keepButton.frame.origin = NSPoint(x: bounds.width - keepButton.frame.width - 10, y: (bar - keepButton.frame.height) / 2)
        reloadButton.frame.origin = NSPoint(x: keepButton.frame.minX - reloadButton.frame.width - 6, y: keepButton.frame.minY)
        conflictText.frame = NSRect(x: 12, y: (bar - 16) / 2, width: max(0, reloadButton.frame.minX - 20), height: 16)
        let body = max(0, bounds.height - h - bar)
        gutter.frame = NSRect(x: 0, y: h + bar, width: gutter.width, height: body)
        scroll.frame = NSRect(x: gutter.width, y: h + bar, width: max(0, bounds.width - gutter.width), height: body)
        preview.frame = NSRect(x: 0, y: h + bar, width: bounds.width, height: body)
        // At least as big as the visible area, so short files still fill it and clicks land in the text.
        text.minSize = scroll.contentSize
        message.frame = NSRect(x: 12, y: bounds.midY - 10, width: max(0, bounds.width - 24), height: 20)
    }
}

private final class CodeTextView: NSTextView {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    /// A new line starts at the same indent as the one before, which is most of what code needs.
    override func insertNewline(_ sender: Any?) {
        let string = self.string as NSString
        let line = string.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let indent = string.substring(with: line).prefix { $0 == " " || $0 == "\t" }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(String(indent), replacementRange: selectedRange()) }
    }
}

/// The gutter left of the text, a plain view beside the scroll view so the text can never slide under it.
/// Only the lines on screen are drawn, so long files stay cheap.
private final class LineNumbers: NSView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private weak var textView: NSTextView?
    /// Where each line starts, as UTF-16 offsets, so the first visible line is a binary search away.
    private var lineStarts: [Int] = [0]
    private(set) var width: CGFloat = 0
    var onResize: (() -> Void)?
    var colors = (background: NSColor.black, text: NSColor.gray) { didSet { needsDisplay = true } }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func textChanged() {
        let string = (textView?.string ?? "") as NSString
        var starts = [0]
        var index = 0
        while index < string.length {
            let range = string.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(range)
            if index < string.length { starts.append(index) }
        }
        lineStarts = starts
        let digits = String(repeating: "8", count: max(3, String(starts.count).count)) as NSString
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
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer,
              !textView.string.isEmpty else { return }
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: colors.text]
        var line = firstLine(atOrBefore: characters.location)
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(characters) {
            let glyph = layout.glyphIndexForCharacter(at: lineStarts[line])
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            // Text view coordinates, shifted by how far it is scrolled. Both views start at the same height.
            let y = fragment.minY + textView.textContainerOrigin.y - visible.minY
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: width - size.width - 10, y: y + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
            line += 1
        }
    }

    private func firstLine(atOrBefore location: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
