import AppKit
import FarolCore
import SwiftUI

/// Colors for a diff, mixed from the terminal theme like the rest of the window.
struct DiffColors: Equatable {
    let background: NSColor
    let foreground: NSColor
    let added: NSColor
    let removed: NSColor
    let muted: NSColor
    /// The band behind "N unmodified lines".
    let band: NSColor

    init(background: NSColor, foreground: NSColor, added: NSColor, removed: NSColor) {
        self.background = background
        self.foreground = foreground
        self.added = added
        self.removed = removed
        muted = background.mixed(with: foreground, 0.45)
        band = background.mixed(with: foreground, 0.035)
    }
}

/// One file's diff in the review panel, as a SwiftUI view.
struct DiffText: NSViewRepresentable {
    let file: Diff.File
    /// The rows to show, when comments split the file into parts. Nil shows them all.
    var rows: Range<Int>? = nil
    let colors: DiffColors
    let syntax: SyntaxColors
    /// Called with a line's number, and whether it counts in the old file, when its "+" in the gutter is clicked. Nil offers no "+".
    var comment: ((Int, _ old: Bool) -> Void)? = nil

    func makeNSView(context: Context) -> DiffScrollView { DiffScrollView() }

    func updateNSView(_ view: DiffScrollView, context: Context) {
        view.text.onComment = comment
        view.text.show(file, rows: rows, colors: colors, syntax: syntax)
        view.needsLayout = true
    }

    /// Every row has the same height, so the size is known without laying the text out.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DiffScrollView, context: Context) -> CGSize? {
        let count = rows?.count ?? DiffTextView.rowCount(file)
        return CGSize(width: proposal.width ?? 400, height: CGFloat(count) * DiffTextView.rowHeight)
    }
}

private extension NSAttributedString.Key {
    static let diffKind = NSAttributedString.Key("farol.diffKind")
    static let diffNumber = NSAttributedString.Key("farol.diffNumber")
    static let diffGap = NSAttributedString.Key("farol.diffGap")
    /// A removed line's number in the old file, for a comment left on it.
    static let diffOldNumber = NSAttributedString.Key("farol.diffOldNumber")
}

/// Scrolls one file's diff sideways, for lines longer than the panel is wide.
/// Up and down belong to the review's own scroll view, so a gesture that starts vertical goes on to it.
final class DiffScrollView: NSScrollView {
    let text = DiffTextView()
    private var sideways = false

    init() {
        super.init(frame: .zero)
        documentView = text
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .none
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func scrollWheel(with event: NSEvent) {
        // Decided once per gesture, so a swipe that drifts doesn't hop between the two scroll views halfway.
        if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            sideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        if sideways { super.scrollWheel(with: event) } else { nextResponder?.scrollWheel(with: event) }
    }

    override func layout() {
        super.layout()
        text.frame = NSRect(x: 0, y: 0, width: max(text.contentWidth, contentSize.width), height: contentSize.height)
    }
}

/// One text view per file, so a selection can run across lines and uses the theme's color, like the file pane.
/// Each line carries its kind and number as attributes, and drawBackground paints the tints and numbers under the text.
final class DiffTextView: NSTextView {
    static let rowHeight: CGFloat = 20
    static let gutter: CGFloat = 58

    private var shown: (file: Diff.File, rows: Range<Int>?, colors: DiffColors, syntax: SyntaxColors)?
    var onComment: ((Int, _ old: Bool) -> Void)? {
        didSet { if (onComment == nil) != (oldValue == nil) { hoveredRow = nil } }
    }
    /// The row whose gutter is under the mouse, where the "+" shows.
    private var hoveredRow: CGFloat? {
        didSet { if hoveredRow != oldValue { needsDisplay = true } }
    }
    /// The width the longest line needs, so the scroll view knows how far it can go.
    private(set) var contentWidth: CGFloat = 0
    private let diffLayout = NSLayoutManager()
    fileprivate var diffColors: DiffColors?

    init() {
        let storage = NSTextStorage()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        storage.addLayoutManager(diffLayout)
        diffLayout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        CodeText.configure(self)
        isEditable = false
        isSelectable = true
        isVerticallyResizable = false
        isHorizontallyResizable = false
        // Views don't clip themselves since macOS 14, and the tints are drawn across the whole width.
        textContainerInset = NSSize(width: Self.gutter, height: 0)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
    }

    /// Rows for hunks plus one for each run of unmodified lines between them.
    static func rowCount(_ file: Diff.File) -> Int {
        rows(file).count
    }

    private enum Row {
        /// A line, with its number in the old file when it is a removed one.
        case line(Diff.Line, old: Int?)
        case gap(Int)
    }

    private static func rows(_ file: Diff.File) -> [Row] {
        var rows: [Row] = []
        var next = 1
        for hunk in file.hunks {
            if hunk.newStart - next > 0 { rows.append(.gap(hunk.newStart - next)) }
            var old = hunk.oldStart
            for line in hunk.lines {
                rows.append(.line(line, old: line.kind == .removed ? old : nil))
                if line.kind != .added { old += 1 }
            }
            next = hunk.newStart + hunk.lines.filter { $0.kind != .removed }.count
        }
        return rows
    }

    /// Which row shows `line`, numbered in the new file, or in the old one for a removed line. Nil when the diff doesn't show it.
    static func row(of line: Int, old: Bool, in file: Diff.File) -> Int? {
        rows(file).firstIndex { row in
            guard case .line(let diffLine, let oldNumber) = row else { return false }
            return old ? oldNumber == line : diffLine.kind != .removed && diffLine.number == line
        }
    }

    /// Rebuilds the text only when the diff or the theme changed, so a refresh keeps your selection.
    func show(_ file: Diff.File, rows slice: Range<Int>? = nil, colors: DiffColors, syntax: SyntaxColors) {
        if let shown, shown.file == file, shown.rows == slice, shown.colors == colors, shown.syntax == syntax { return }
        shown = (file, slice, colors, syntax)
        diffColors = colors
        CodeText.apply(to: self, background: colors.background, foreground: colors.foreground)

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Self.rowHeight
        paragraph.maximumLineHeight = Self.rowHeight
        // Centers the text in its row, which is taller than the font's own line.
        let baseline = (Self.rowHeight - diffLayout.defaultLineHeight(for: CodeText.font)) / 2
        let base: [NSAttributedString.Key: Any] = [
            .font: CodeText.font, .foregroundColor: colors.foreground, .paragraphStyle: paragraph, .baselineOffset: baseline,
        ]
        let text = NSMutableAttributedString()
        let rows = Self.rows(file)
        for row in rows[slice ?? rows.indices] {
            var attributes = base
            var line = ""
            switch row {
            case .gap(let count):
                attributes[.diffGap] = count
            case .line(let diffLine, let old):
                // Tabs would line up differently from the file, so they show as four spaces.
                line = diffLine.text.replacingOccurrences(of: "\t", with: "    ")
                attributes[.diffKind] = diffLine.kind == .added ? 1 : diffLine.kind == .removed ? -1 : 0
                if let number = diffLine.number { attributes[.diffNumber] = number }
                if let old { attributes[.diffOldNumber] = old }
            }
            // Every row ends with a newline, so even an empty one has a glyph and gets its background drawn.
            text.append(NSAttributedString(string: line + "\n", attributes: attributes))
        }
        textStorage?.setAttributedString(text)
        if let storage = textStorage {
            CodeText.highlight(storage, Syntax.language(for: file.path), syntax, plain: colors.foreground)
        }
        if let container = textContainer {
            diffLayout.ensureLayout(for: container)
            contentWidth = ceil(diffLayout.usedRect(for: container).width) + Self.gutter + 16
        }
        enclosingScrollView?.needsLayout = true
        needsDisplay = true
    }
}

extension DiffTextView {
    /// Paints each row's full-width tint, colored bar, line number and gap label. AppKit then draws the selection and text on top.
    /// This runs in the view's own background pass, because the layout manager can't draw left of the text.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let colors = diffColors, let layout = layoutManager, let container = textContainer, let storage = textStorage else { return }
        let origin = textContainerOrigin
        let visible = NSRect(x: 0, y: rect.minY - origin.y, width: 100_000, height: rect.height)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let index = layout.characterIndexForGlyph(at: glyphRange.location)
            guard index < storage.length else { return }
            let attributes = storage.attributes(at: index, effectiveRange: nil)
            let row = NSRect(x: 0, y: fragment.minY + origin.y, width: self.bounds.width, height: fragment.height)

            if let gap = attributes[.diffGap] as? Int {
                colors.band.setFill()
                row.fill()
                let label = "\(gap) unmodified \(gap == 1 ? "line" : "lines")" as NSString
                let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: colors.muted]
                let size = label.size(withAttributes: style)
                label.draw(at: NSPoint(x: Self.gutter, y: row.midY - size.height / 2), withAttributes: style)
                return
            }
            let kind = attributes[.diffKind] as? Int ?? 0
            if kind != 0 {
                let tint = kind > 0 ? colors.added : colors.removed
                tint.withAlphaComponent(0.14).setFill()
                row.fill()
                tint.withAlphaComponent(0.9).setFill()
                NSRect(x: 0, y: row.minY, width: 3, height: row.height).fill()
            }
            if self.onComment != nil, self.hoveredRow == row.minY {
                Self.drawPlus(in: row, colors: colors)
            }
            if let number = attributes[.diffNumber] as? Int {
                let label = "\(number)" as NSString
                let style: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: colors.muted]
                let size = label.size(withAttributes: style)
                label.draw(at: NSPoint(x: Self.gutter - 11 - size.width, y: row.midY - size.height / 2), withAttributes: style)
            }
        }
    }
}

/// The "+" in the gutter that starts a comment on a line, as on GitHub.
extension DiffTextView {
    fileprivate static func drawPlus(in row: NSRect, colors: DiffColors) {
        let box = NSRect(x: 5, y: row.midY - 7, width: 14, height: 14)
        colors.foreground.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        colors.background.setFill()
        NSRect(x: box.midX - 3.5, y: box.midY - 0.6, width: 7, height: 1.2).fill()
        NSRect(x: box.midX - 0.6, y: box.midY - 3.5, width: 1.2, height: 7).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Only ours: the text view keeps its own, for the cursor.
        trackingAreas.filter { $0.userInfo?["farol.gutter"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: ["farol.gutter": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoveredRow = commentable(at: convert(event.locationInWindow, from: nil)).map(\.row.minY)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredRow = nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x < Self.gutter, let line = commentable(at: point) else { return super.mouseDown(with: event) }
        onComment?(line.number, line.old)
    }

    /// The line under `point` that a comment can go on: a line of the diff, not a run of unmodified ones, while comments are offered.
    private func commentable(at point: NSPoint) -> (number: Int, old: Bool, row: NSRect)? {
        guard onComment != nil, let layout = layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: point.y - origin.y), in: container)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let row = NSRect(x: 0, y: fragment.minY + origin.y, width: bounds.width, height: fragment.height)
        guard row.contains(NSPoint(x: 0, y: point.y)) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        let attributes = storage.attributes(at: index, effectiveRange: nil)
        if let old = attributes[.diffOldNumber] as? Int { return (old, true, row) }
        return (attributes[.diffNumber] as? Int).map { ($0, false, row) }
    }
}
