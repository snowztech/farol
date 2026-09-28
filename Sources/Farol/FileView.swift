import AppKit
import FarolCore

/// A pane that shows a file: a header with its name, then the text with line numbers. Read-only for now.
final class FileView: NSView {
    private static let headerHeight: CGFloat = 26

    private(set) var path = ""
    var onFocus: (() -> Void)?
    var onClose: (() -> Void)?

    private let header = NSView()
    private let title = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let scroll = NSScrollView()
    private let text: FocusReportingTextView
    private let gutter: LineNumbers
    /// Shown instead of the text for binary files, files too big to open, or errors.
    private let message = NSTextField(labelWithString: "")

    init(path: String) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        text = FocusReportingTextView(frame: .zero, textContainer: container)
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

        // Code keeps its lines: no wrapping, scroll sideways instead.
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = []
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        container.widthTracksTextView = false
        text.textContainerInset = NSSize(width: 8, height: 6)
        text.font = Self.font
        text.onFocus = { [weak self] in self?.onFocus?() }

        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in self?.gutter.needsDisplay = true }

        message.alignment = .center
        message.isHidden = true

        for view in [header, scroll, message] { addSubview(view) }
        show(path)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    var textView: NSTextView { text }

    /// Loads another file into the same pane.
    func show(_ path: String) {
        self.path = path
        title.stringValue = (path as NSString).lastPathComponent
        title.toolTip = (path as NSString).abbreviatingWithTildeInPath
        let content = Result { try Files.read(path) }
        switch content {
        case .success(.text(let string)):
            text.string = string
            display(message: nil)
        case .success(.binary):
            display(message: "This file isn't text.")
        case .success(.tooLarge):
            display(message: "This file is too large to show here.")
        case .failure(let error):
            display(message: error.localizedDescription)
        }
        gutter.textChanged()
        text.scroll(.zero)
    }

    private func display(message text: String?) {
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        scroll.isHidden = text != nil
    }

    func apply(background: NSColor, foreground: NSColor) {
        layer?.backgroundColor = background.cgColor
        header.layer?.backgroundColor = background.mixed(with: foreground, 0.035).cgColor
        title.textColor = background.mixed(with: foreground, 0.75)
        closeButton.contentTintColor = background.mixed(with: foreground, 0.55)
        message.textColor = background.mixed(with: foreground, 0.55)
        scroll.backgroundColor = background
        text.backgroundColor = background
        text.textColor = foreground
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
        scroll.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        // At least as big as the visible area, so short files still fill it and clicks land in the text.
        text.minSize = scroll.contentSize
        message.frame = NSRect(x: 12, y: bounds.midY - 10, width: max(0, bounds.width - 24), height: 20)
    }
}

private final class FocusReportingTextView: NSTextView {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

/// The gutter left of the text. Only the lines on screen are drawn, so long files stay cheap.
private final class LineNumbers: NSRulerView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private weak var textView: NSTextView?
    /// Where each line starts, as UTF-16 offsets, so the first visible line is a binary search away.
    private var lineStarts: [Int] = [0]
    var colors = (background: NSColor.black, text: NSColor.gray) { didSet { needsDisplay = true } }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
    }

    required init(coder: NSCoder) { fatalError("not used") }

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
        ruleThickness = digits.size(withAttributes: [.font: Self.font]).width + 20
        // The scroll view doesn't make room for a wider gutter on its own, and the text would slide under it.
        scrollView?.tile()
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
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
            let y = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), from: textView).y
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: y + (fragment.height - size.height) / 2),
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
