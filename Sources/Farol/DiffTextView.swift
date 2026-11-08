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
    /// Behind what the search found, and behind the match it is on.
    let match: NSColor
    let currentMatch: NSColor

    init(background: NSColor, foreground: NSColor, added: NSColor, removed: NSColor, highlight: NSColor) {
        self.background = background
        self.foreground = foreground
        self.added = added
        self.removed = removed
        muted = background.mixed(with: foreground, 0.45)
        band = background.mixed(with: foreground, 0.035)
        match = background.mixed(with: highlight, 0.3)
        currentMatch = highlight
    }
}

/// Where your notes are in one file: a dot beside each line one covers, and a tint on the lines of the note under the mouse.
struct DiffNotes: Equatable {
    var lines: Set<Int> = []
    var oldLines: Set<Int> = []
    var lit: ClosedRange<Int>?
    var litOld = false
    let color: NSColor
}

/// Lines an agent just wrote, while the review follows it. They show brighter for a moment, so you see them arrive.
struct FreshLines: Equatable {
    let path: String
    let lines: ClosedRange<Int>
    let at = Date()
    static let lasts: TimeInterval = 2.5
}

/// The matches of the review's search in one file, by row, and the one the search is on.
struct DiffMarks: Equatable {
    /// The characters to mark in each row's text, as the diff shows it.
    var ranges: [Int: [NSRange]] = [:]
    var currentRow: Int?
    var currentLocation = 0
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
    /// Called with the first and last line of a selection, from the right-click menu. Nil offers no note on several lines.
    var noteLines: ((Int, Int, _ old: Bool) -> Void)? = nil
    /// Called with a gap's unmodified lines, by their numbers in the new file, and whether to show them from the top, next to the hunk above.
    /// Nil leaves gaps closed.
    var expand: ((Range<Int>, _ fromTop: Bool) -> Void)? = nil
    /// While the lines of a gap are being read, which takes a moment for a request. The clicked gap shows a spinner meanwhile.
    var loading = false
    var marks: DiffMarks? = nil
    var notes: DiffNotes? = nil
    var fresh: FreshLines? = nil

    func makeNSView(context: Context) -> DiffScrollView { DiffScrollView() }

    func updateNSView(_ view: DiffScrollView, context: Context) {
        view.text.onComment = comment
        view.text.onNoteLines = noteLines
        view.text.notes = notes
        view.text.fresh = fresh
        view.text.onExpand = expand
        view.text.loading = loading
        view.text.show(file, rows: rows, colors: colors, syntax: syntax, marks: marks)
        view.needsLayout = true
    }

    /// Every row has the same height, so the size is known without laying the text out.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DiffScrollView, context: Context) -> CGSize? {
        return CGSize(width: proposal.width ?? 400, height: DiffTextView.height(file, rows: rows, expandable: expand != nil))
    }
}

private extension NSAttributedString.Key {
    static let diffKind = NSAttributedString.Key("farol.diffKind")
    static let diffNumber = NSAttributedString.Key("farol.diffNumber")
    static let diffGap = NSAttributedString.Key("farol.diffGap")
    /// The first and last line number of a gap, for the click that expands it.
    static let diffGapRange = NSAttributedString.Key("farol.diffGapRange")
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

    private var shown: (file: Diff.File, rows: Range<Int>?, colors: DiffColors, syntax: SyntaxColors, expandable: Bool)?
    /// Where each row's text starts in the view, for the rows it shows.
    private var rowStarts: [Int: Int] = [:]
    private var shownMarks: DiffMarks?
    var onExpand: ((Range<Int>, _ fromTop: Bool) -> Void)? {
        didSet { if (onExpand == nil) != (oldValue == nil) { needsDisplay = true } }
    }
    /// The gap clicked and still waiting for its lines.
    private var waiting: (lines: Range<Int>, fromTop: Bool)? {
        didSet { if (waiting == nil) != (oldValue == nil) { spin() } else if waiting?.lines != oldValue?.lines { needsDisplay = true } }
    }
    var loading = false {
        didSet { if !loading { waiting = nil } }
    }
    private var spinner: Timer?
    private var turn: CGFloat = 0
    /// The gutter of the clicked gap's row, the only part the spinner redraws.
    private var spinnerRow = NSRect.zero

    private func spin() {
        spinner?.invalidate()
        spinner = nil
        needsDisplay = true
        guard waiting != nil else { return }
        spinner = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.turn += 0.2
            self.setNeedsDisplay(self.spinnerRow)
        }
    }

    deinit { spinner?.invalidate() }

    var onComment: ((Int, _ old: Bool) -> Void)? {
        didSet { if (onComment == nil) != (oldValue == nil) { hoveredRow = nil } }
    }
    var onNoteLines: ((Int, Int, _ old: Bool) -> Void)?
    var notes: DiffNotes? {
        didSet { if notes != oldValue { needsDisplay = true } }
    }
    var fresh: FreshLines? {
        didSet { if fresh != oldValue { fade() } }
    }
    private var fadeTimer: Timer?

    /// Redraws while fresh lines fade, then once more without them.
    private func fade() {
        fadeTimer?.invalidate()
        needsDisplay = true
        guard fresh != nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self, let fresh, Date().timeIntervalSince(fresh.at) < FreshLines.lasts else {
                timer.invalidate()
                self?.needsDisplay = true
                return
            }
            needsDisplay = true
        }
    }
    /// The row whose gutter is under the mouse, where the "+" shows.
    private var hoveredRow: CGFloat? {
        didSet { if hoveredRow != oldValue { needsDisplay = true } }
    }
    /// The id of the review row this view draws, to find it again in the list.
    var rowID: String? { shown.map { "\($0.file.path)#body\($0.rows?.lowerBound ?? 0)" } }
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

    /// A gap with a hunk above holds two buttons, one over the other, so it is two rows tall while they show.
    static func height(_ file: Diff.File, rows slice: Range<Int>?, expandable: Bool) -> CGFloat {
        let all = rows(file)
        return all[slice ?? all.indices].reduce(0) { total, row in
            if case .gap(_, above: true) = row, expandable { return total + rowHeight * 2 }
            return total + rowHeight
        }
    }

    private enum Row {
        /// A line, with its number in the old file when it is a removed one.
        case line(Diff.Line, old: Int?)
        /// `above` is whether a hunk comes before it, so lines can be shown from either end.
        case gap(Range<Int>, above: Bool)
    }

    private static func rows(_ file: Diff.File) -> [Row] {
        var rows: [Row] = []
        var next = 1
        for hunk in file.hunks {
            if hunk.newBegin > next { rows.append(.gap(next..<hunk.newBegin, above: next > 1)) }
            var old = hunk.oldStart
            for line in hunk.lines {
                rows.append(.line(line, old: line.kind == .removed ? old : nil))
                if line.kind != .added { old += 1 }
            }
            next = hunk.newEnd
        }
        return rows
    }

    /// Each row of lines with the text as the diff shows it, for a search to look through.
    static func lines(_ file: Diff.File) -> [(row: Int, text: String)] {
        rows(file).enumerated().compactMap { index, row in
            guard case .line(let line, _) = row else { return nil }
            return (index, line.text.replacingOccurrences(of: "\t", with: "    "))
        }
    }

    /// Where `row` of `path` is in this view's own coordinates, when this view shows it.
    func rect(ofRow row: Int, in path: String) -> NSRect? {
        guard let shown, shown.file.path == path, let start = rowStarts[row], let container = textContainer else { return nil }
        let glyph = diffLayout.glyphIndexForCharacter(at: start)
        let fragment = diffLayout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSRect(x: 0, y: fragment.minY + textContainerOrigin.y, width: container.size.width, height: fragment.height)
    }

    /// Which row shows `line`, numbered in the new file, or in the old one for a removed line. Nil when the diff doesn't show it.
    static func row(of line: Int, old: Bool, in file: Diff.File) -> Int? {
        rows(file).firstIndex { row in
            guard case .line(let diffLine, let oldNumber) = row else { return false }
            return old ? oldNumber == line : diffLine.kind != .removed && diffLine.number == line
        }
    }

    /// Rebuilds the text only when the diff or the theme changed, so a refresh keeps your selection.
    func show(_ file: Diff.File, rows slice: Range<Int>? = nil, colors: DiffColors, syntax: SyntaxColors, marks: DiffMarks? = nil) {
        let expandable = onExpand != nil
        if let shown, shown.file == file, shown.rows == slice, shown.colors == colors, shown.syntax == syntax,
           shown.expandable == expandable {
            if marks != shownMarks { mark(marks) }
            return
        }
        shown = (file, slice, colors, syntax, expandable)
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
        rowStarts = [:]
        for (index, row) in zip(rows.indices, rows) where (slice ?? rows.indices).contains(index) {
            rowStarts[index] = text.length
            var attributes = base
            var line = ""
            switch row {
            case .gap(let lines, let above):
                attributes[.diffGap] = lines.count
                attributes[.diffGapRange] = [lines.lowerBound, lines.upperBound, above ? 1 : 0]
                if above, expandable {
                    let tall = NSMutableParagraphStyle()
                    tall.minimumLineHeight = Self.rowHeight * 2
                    tall.maximumLineHeight = Self.rowHeight * 2
                    attributes[.paragraphStyle] = tall
                }
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
        mark(marks)
        if let container = textContainer {
            diffLayout.ensureLayout(for: container)
            contentWidth = ceil(diffLayout.usedRect(for: container).width) + Self.gutter + 16
        }
        enclosingScrollView?.needsLayout = true
        needsDisplay = true
    }
}

extension DiffTextView {
    /// Marks the search's matches, the current one strongest.
    /// Temporary attributes leave the text alone, so stepping doesn't lay out and color the diff again, and keeps your selection.
    fileprivate func mark(_ marks: DiffMarks?) {
        shownMarks = marks
        guard let storage = textStorage, let colors = shown?.colors else { return }
        let all = NSRange(location: 0, length: storage.length)
        diffLayout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        diffLayout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        guard let marks else { return }
        for (row, ranges) in marks.ranges {
            guard let start = rowStarts[row] else { continue }
            for range in ranges {
                let located = NSRange(location: start + range.location, length: range.length)
                guard NSMaxRange(located) <= storage.length else { continue }
                let current = marks.currentRow == row && marks.currentLocation == range.location
                diffLayout.addTemporaryAttributes(
                    current ? [.backgroundColor: colors.currentMatch, .foregroundColor: colors.background] : [.backgroundColor: colors.match],
                    forCharacterRange: located)
            }
        }
    }

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
                if self.onExpand != nil {
                    let both = (attributes[.diffGapRange] as? [Int])?.last == 1
                    if let lines = (attributes[.diffGapRange] as? [Int]).map({ $0[0]..<$0[1] }), let waiting = self.waiting, waiting.lines == lines {
                        Self.drawSpinner(in: row, upper: both && waiting.fromTop, turn: self.turn, colors: colors)
                    } else {
                        Self.drawExpanders(in: row, both: both, colors: colors)
                    }
                }
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
            if let fresh = self.fresh, let number = attributes[.diffNumber] as? Int, fresh.lines.contains(number) {
                let left = 1 - Date().timeIntervalSince(fresh.at) / FreshLines.lasts
                if left > 0 {
                    colors.added.withAlphaComponent(0.4 * left).setFill()
                    row.fill()
                }
            }
            if let notes = self.notes {
                let new = attributes[.diffNumber] as? Int
                let old = attributes[.diffOldNumber] as? Int
                if let lit = notes.lit, let number = notes.litOld ? old : new, lit.contains(number) {
                    notes.color.withAlphaComponent(0.12).setFill()
                    row.fill()
                }
                if new.map(notes.lines.contains) == true || old.map(notes.oldLines.contains) == true {
                    notes.color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: 9, y: row.midY - 2.5, width: 5, height: 5)).fill()
                }
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

    /// The buttons in a gap's gutter, as on GitHub but quieter. The upper one shows lines below the hunk above, the lower one lines above the hunk below.
    /// A gap at the top of the file only has the lower one.
    fileprivate static func drawExpanders(in row: NSRect, both: Bool, colors: DiffColors) {
        let center = gutter / 2
        colors.muted.setStroke()
        colors.muted.setFill()
        func dots(at y: CGFloat) {
            for offset in [-5, 0, 5] as [CGFloat] { NSRect(x: center + offset - 1, y: y - 0.75, width: 2, height: 1.5).fill() }
        }
        func arrow(from tail: CGFloat, to tip: CGFloat) {
            let path = NSBezierPath()
            path.lineWidth = 1.4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: center, y: tail))
            path.line(to: NSPoint(x: center, y: tip))
            let back: CGFloat = tip > tail ? -3.5 : 3.5
            path.move(to: NSPoint(x: center - 3.5, y: tip + back))
            path.line(to: NSPoint(x: center, y: tip))
            path.line(to: NSPoint(x: center + 3.5, y: tip + back))
            path.stroke()
        }
        if both {
            dots(at: row.minY + 5)
            arrow(from: row.minY + 8, to: row.minY + 16)
        }
        let lower = both ? row.minY + rowHeight : row.minY
        arrow(from: lower + 12, to: lower + 4)
        dots(at: lower + 15)
    }

    /// Stands in for the buttons of the gap that was clicked: an open ring turning in the gutter.
    fileprivate static func drawSpinner(in row: NSRect, upper: Bool, turn: CGFloat, colors: DiffColors) {
        let lower = row.minY + (row.height > rowHeight && !upper ? rowHeight : 0)
        let center = NSPoint(x: gutter / 2, y: lower + 10)
        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        let start = turn * 180 / .pi
        path.appendArc(withCenter: center, radius: 5, startAngle: start, endAngle: start + 270)
        colors.muted.setStroke()
        path.stroke()
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
        let point = convert(event.locationInWindow, from: nil)
        hoveredRow = commentable(at: point).map(\.row.minY)
        if gap(at: point) != nil, point.x < Self.gutter { NSCursor.pointingHand.set() }
        // The text view has just set its I-beam. Over the gutter, where a click starts a comment, it's a hand.
        if hoveredRow != nil, point.x < Self.gutter { NSCursor.pointingHand.set() }
    }

    /// Selected lines take one note together, from the menu, with the first and last line in the new file.
    /// A selection of only removed lines counts in the old one.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let onNoteLines, let storage = textStorage, selectedRange().length > 0 else { return menu }
        var new: [Int] = []
        var old: [Int] = []
        storage.enumerateAttributes(in: selectedRange()) { attributes, _, _ in
            if let number = attributes[.diffNumber] as? Int { new.append(number) } else if let number = attributes[.diffOldNumber] as? Int { old.append(number) }
        }
        let lines = new.isEmpty ? old : new
        guard let first = lines.min(), let last = lines.max() else { return menu }
        let title = first == last ? "Add Note on Line \(first)" : "Add Note on Lines \(first)–\(last)"
        menu.insertItem(ActionMenuItem(title: title) { onNoteLines(first, last, new.isEmpty) }, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredRow = nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x < Self.gutter, let target = gap(at: point) {
            // One read at a time: a second click would only ask the forge again.
            guard waiting == nil else { return }
            spinnerRow = target.row
            waiting = (target.lines, target.fromTop)
            return onExpand?(target.lines, target.fromTop) ?? ()
        }
        guard point.x < Self.gutter, let line = commentable(at: point) else { return super.mouseDown(with: event) }
        onComment?(line.number, line.old)
    }

    /// The unmodified lines of the gap row under `point`, and whether the point is on its upper button, while gaps can be expanded.
    private func gap(at point: NSPoint) -> (lines: Range<Int>, fromTop: Bool, row: NSRect)? {
        guard onExpand != nil, let layout = layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: point.y - origin.y), in: container)
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length,
              let bounds = storage.attributes(at: index, effectiveRange: nil)[.diffGapRange] as? [Int], bounds.count == 3 else { return nil }
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let top = bounds[2] == 1 && point.y - origin.y < fragment.minY + fragment.height / 2
        return (bounds[0]..<bounds[1], top, NSRect(x: 0, y: fragment.minY + origin.y, width: Self.gutter, height: fragment.height))
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
