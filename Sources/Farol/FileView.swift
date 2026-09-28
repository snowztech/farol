import AppKit
import FarolCore

/// A pane that shows a file: a header with its name, then the text with line numbers.
/// Edits are saved with ⌘S. When an agent changes the file on disk, it reloads, or asks if you have unsaved edits.
final class FileView: NSView {
    private static let headerHeight: CGFloat = 26
    private static let barHeight: CGFloat = 30

    private(set) var path = ""
    private(set) var isDirty = false { didSet { updateTitle() } }
    var onFocus: (() -> Void)?
    var onClose: (() -> Void)?

    /// The file as last read or saved, to tell our own save from someone else's change.
    private var onDisk: String?
    private var watcher: DispatchSourceFileSystemObject?

    private let header = NSView()
    private let title = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    /// Shown when the file changed on disk while you had unsaved edits.
    private let conflict = NSView()
    private let conflictText = NSTextField(labelWithString: "Changed on disk while you were editing.")
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let keepButton = NSButton(title: "Keep Mine", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let text: CodeTextView
    private let gutter: LineNumbers
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
        title.lineBreakMode = .byTruncatingMiddle
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close file")
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.toolTip = "Close file (⌘W)"
        header.wantsLayer = true
        header.addSubview(title)
        header.addSubview(closeButton)

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

        // Code keeps its lines: no wrapping, scroll sideways instead. No smart quotes or other prose helpers.
        text.isRichText = false
        text.allowsUndo = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = []
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        container.widthTracksTextView = false
        text.textContainerInset = NSSize(width: 8, height: 6)
        text.font = Self.font
        text.onFocus = { [weak self] in self?.onFocus?() }
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: text, queue: .main) { [weak self] _ in
            self?.isDirty = true
            self?.gutter.textChanged()
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

        gutter.onResize = { [weak self] in self?.needsLayout = true }
        for view in [header, conflict, gutter, scroll, message] { addSubview(view) }
        show(path)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { watcher?.cancel() }

    override var isFlipped: Bool { true }

    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    var textView: NSTextView { text }

    /// Loads another file into the same pane. Callers check `isDirty` first, see confirmClose.
    func show(_ path: String) {
        self.path = path
        title.toolTip = (path as NSString).abbreviatingWithTildeInPath
        load(keepingPosition: false)
        watch()
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
        scroll.isHidden = text != nil
        gutter.isHidden = text != nil
    }

    /// The name, then a small dot for unsaved edits, centered on the text rather than sitting on its baseline.
    private func updateTitle() {
        let color = title.textColor ?? .labelColor
        let result = NSMutableAttributedString(
            string: (path as NSString).lastPathComponent, attributes: [.font: title.font!, .foregroundColor: color])
        if isDirty {
            result.append(NSAttributedString(
                string: "  ●", attributes: [.font: NSFont.systemFont(ofSize: 7), .foregroundColor: color, .baselineOffset: 2]))
        }
        title.attributedStringValue = result
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
        conflict.isHidden = true
        needsLayout = true
    }

    // MARK: Appearance

    func apply(background: NSColor, foreground: NSColor) {
        layer?.backgroundColor = background.cgColor
        header.layer?.backgroundColor = background.mixed(with: foreground, 0.035).cgColor
        conflict.layer?.backgroundColor = background.mixed(with: foreground, 0.07).cgColor
        conflictText.textColor = foreground
        title.textColor = background.mixed(with: foreground, 0.75)
        updateTitle()
        closeButton.contentTintColor = background.mixed(with: foreground, 0.55)
        message.textColor = background.mixed(with: foreground, 0.55)
        scroll.backgroundColor = background
        text.backgroundColor = background
        text.textColor = foreground
        text.typingAttributes = [.font: Self.font, .foregroundColor: foreground]
        text.insertionPointColor = foreground
        text.selectedTextAttributes = [.backgroundColor: background.mixed(with: foreground, 0.22)]
        gutter.colors = (background, background.mixed(with: foreground, 0.35))
    }

    /// ⌘F, ⌘G and ⌘E use the text view's own find bar while the file has focus.
    func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        text.performTextFinderAction(item)
    }

    @objc private func close() { onClose?() }

    override func layout() {
        super.layout()
        let h = Self.headerHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        closeButton.frame = NSRect(x: bounds.width - 28, y: 3, width: 20, height: 20)
        title.frame = NSRect(x: 12, y: 5, width: max(0, bounds.width - 48), height: 16)
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
