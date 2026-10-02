import AppKit
import FarolCore

/// Colors for the merge view, from the terminal theme.
struct MergeColors: Equatable {
    let background: NSColor
    let foreground: NSColor
    let muted: NSColor
    let line: NSColor
    /// Your side, the incoming side, a chunk still waiting for a decision, the result once decided, and what was left out.
    let mine: NSColor
    let other: NSColor
    let pending: NSColor
    let resolved: NSColor
    let dropped: NSColor

    init(_ palette: Palette) {
        background = NSColor(palette.background)
        foreground = NSColor(palette.text)
        muted = NSColor(palette.muted)
        line = NSColor(palette.line)
        mine = NSColor(palette.working)
        other = palette.code.keyword
        pending = NSColor(palette.waiting)
        resolved = palette.diff.added
        dropped = palette.diff.removed
    }
}

/// Three columns, like IntelliJ's merge: your version, the result, the incoming version.
/// Each change has an arrow to bring it into the result and a cross to leave it out, and a conflict needs both sides decided.
/// Changes only one side made are taken from the start and folded away with the unchanged lines, so only what needs you shows.
final class MergeEditor: NSView, NSTextStorageDelegate, NSTextViewDelegate {
    static let rowHeight: CGFloat = 20
    /// Between a side and the result, as in IntelliJ: the side's buttons and line numbers on its band, then the wave.
    private static let waveWidth: CGFloat = 30
    static let buttonsWidth: CGFloat = 44
    private static var gutterWidth: CGFloat { buttonsWidth + MergeNumbers.width + waveWidth }
    /// Unchanged lines kept around each change, like a diff.
    private static let context = 3
    /// A change this close to a conflict stays in view, since it may depend on how the conflict goes.
    private static let near = 3

    /// After every decision or edit, so the counts around the editor follow.
    var onChange: (() -> Void)?
    var onEscape: (() -> Void)?

    private(set) var path = ""
    private(set) var merge: ThreeWay?
    private var language: Syntax.Language?
    private var syntax: SyntaxColors?
    private var colors: MergeColors?

    /// Decisions and the result's text. Visible units live in the center text, which is read back into it before each rebuild.
    private var resolution = MergeResolution(ThreeWay(base: "", mine: "", other: ""))
    private var units: [MergeResolution.Unit] { resolution.units }
    var decisions: [MergeResolution.Decision] { resolution.decisions }
    /// Where each unit starts in your version and in the incoming one, to number lines.
    private var starts: [(mine: Int, other: Int)] = []
    /// Names the result still uses but no longer declares. Refreshed after each change.
    private(set) var warnings: [Merge.Undeclared] = []
    /// The three versions as text, for the check above.
    private var versionTexts: [String] = []
    private var checks = 0
    private var nearConflict: [Bool] = []
    /// Folds you opened, by their first unit.
    private var expanded: Set<Int> = []
    var showAll = false {
        didSet { if showAll != oldValue { rebuild() } }
    }

    /// A file's work in progress, kept while you look at another file.
    struct Work {
        fileprivate let resolution: MergeResolution
        fileprivate let expanded: Set<Int>
        let showAll: Bool
        fileprivate let undo: UndoManager
        var merge: ThreeWay { resolution.merge }

        /// This work on the file read another way. Undo starts over, since its steps belong to the other reading.
        func carried(to merge: ThreeWay) -> Work? {
            resolution.carried(to: merge).map { Work(resolution: $0, expanded: expanded, showAll: showAll, undo: UndoManager()) }
        }
    }

    var work: Work {
        sync()
        centerView.breakUndoCoalescing()
        return Work(resolution: resolution, expanded: expanded, showAll: showAll, undo: undo)
    }

    private enum Item: Equatable {
        case unit(Int)
        case fold(Range<Int>)
    }

    /// The center text, item by item, kept current while you type.
    private var items: [(item: Item, range: NSRange)] = []
    /// The item of each visible chunk.
    private var chunkItems: [Int: Int] = [:]
    /// What the columns were last built from, to tell when only the result's text needs to change.
    private var built: (visible: [Bool], resolution: MergeResolution)?
    /// Where each visible chunk sits in the side columns.
    private var sideRanges: [Int: (mine: NSRange, other: NSRange)] = [:]
    private var sideFolds: (mine: [(NSRange, Int)], other: [(NSRange, Int)]) = ([], [])
    /// Runs of display blocks shared by the three columns, to keep them scrolled together.
    private var blocks: [(mine: NSRange, items: Range<Int>, other: NSRange)] = []
    private var applying = false
    private var current: Int?
    private var syncing = false
    private var pendingHighlight: DispatchWorkItem?
    /// One per file, so each file keeps its own history.
    private var undo = UndoManager()

    private let mineView = MergeTextView()
    private let centerView = MergeTextView()
    private let otherView = MergeTextView()
    private lazy var columns = [mineView, centerView, otherView]
    private let leftGutter = MergeGutter(mine: true)
    private let rightGutter = MergeGutter(mine: false)
    private let markers = MergeMarkers()
    private let mineNumbers = MergeNumbers()
    private let centerNumbers = MergeNumbers()
    private let otherNumbers = MergeNumbers()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // A wave to a change scrolled out of view would otherwise run up over the titles above.
        clipsToBounds = true
        for view in columns {
            addSubview(view.scroll)
            view.onFoldClick = { [weak self] in self?.unfold($0) }
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: view.scroll.contentView,
                                                   queue: .main) { [weak self] _ in self?.scrolled(view) }
        }
        mineView.isEditable = false
        otherView.isEditable = false
        centerView.isEditable = true
        centerView.allowsUndo = true
        centerView.delegate = self
        centerView.textStorage?.delegate = self
        centerView.onEscape = { [weak self] in self?.onEscape?() }
        mineView.onEscape = centerView.onEscape
        otherView.onEscape = centerView.onEscape
        centerView.onJump = { [weak self] in self?.jump(forward: $0) }
        // Only the center scrolls with a visible bar. The sides follow it.
        mineView.scroll.hasVerticalScroller = false
        otherView.scroll.hasVerticalScroller = false
        for gutter in [leftGutter, rightGutter] {
            gutter.editor = self
            gutter.strip = Self.buttonsWidth + MergeNumbers.width
            addSubview(gutter)
        }
        for (numbers, view) in [(mineNumbers, mineView), (centerNumbers, centerView), (otherNumbers, otherView)] {
            numbers.textView = view
            addSubview(numbers)
        }
        otherNumbers.alignRight = true
        // The sides' numbers sit on the gutter, over the band of the change on their row.
        mineNumbers.fillsBackground = false
        otherNumbers.fillsBackground = false
        markers.onClick = { [weak self] in self?.reveal(resultLine: $0) }
        markers.textView = centerView
        addSubview(markers)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    var textView: NSTextView { centerView }

    // MARK: Loading

    /// Shows a file from the start, or as you left it when `work` is given.
    func show(_ path: String, _ merge: ThreeWay, work: Work? = nil) {
        self.path = path
        self.merge = merge
        language = Syntax.language(for: path)
        resolution = work?.resolution ?? MergeResolution(merge)
        expanded = work?.expanded ?? []
        starts = []
        var shiftMine = 0, shiftOther = 0
        for unit in units {
            switch unit {
            case .line(let line):
                starts.append((line + shiftMine, line + shiftOther))
            case .chunk(let index):
                let chunk = merge.chunks[index]
                starts.append((chunk.mine.lowerBound, chunk.other.lowerBound))
                shiftMine = chunk.mine.upperBound - chunk.base.upperBound
                shiftOther = chunk.other.upperBound - chunk.base.upperBound
            }
        }
        let conflicts = merge.chunks.filter { $0.kind == .conflict }
        nearConflict = merge.chunks.map { chunk in
            conflicts.contains { other in
                let gap = max(other.base.lowerBound - chunk.base.upperBound, chunk.base.lowerBound - other.base.upperBound)
                return gap <= Self.near
            }
        }
        versionTexts = [merge.base, merge.mine, merge.other].map { $0.joined(separator: "\n") }
        warnings = []
        centerView.breakUndoCoalescing()
        undo = work?.undo ?? UndoManager()
        built = nil
        rebuild(keepScroll: false)
        check()
        jump(forward: true, from: -1)
    }

    func apply(colors: MergeColors, syntax: SyntaxColors) {
        guard colors != self.colors || syntax != self.syntax else { return }
        self.colors = colors
        self.syntax = syntax
        layer?.backgroundColor = colors.background.cgColor
        for view in columns {
            CodeText.apply(to: view, background: colors.background, foreground: colors.foreground)
            view.typingAttributes = baseAttributes(colors)
            view.scroll.backgroundColor = colors.background
        }
        for numbers in [mineNumbers, centerNumbers, otherNumbers] { numbers.colors = (colors.background, colors.muted) }
        built = nil
        if merge != nil { rebuild() }
    }

    // MARK: State

    func sides(_ index: Int) -> (mine: Bool, other: Bool) {
        merge == nil ? (false, false) : resolution.sides(index)
    }

    func isDecided(_ index: Int) -> Bool { resolution.isDecided(index) }

    var openDecisions: Int { merge == nil ? 0 : resolution.openDecisions }
    /// Changes still waiting for you. A conflict is one change, though each of its sides is a decision.
    var openChanges: Int { merge?.chunks.indices.filter { !isDecided($0) }.count ?? 0 }
    var conflictCount: Int { merge == nil ? 0 : resolution.conflictCount }
    var autoCount: Int { resolution.autoCount }

    /// The file as it will be written.
    var result: String {
        sync()
        return merge == nil ? "" : resolution.result
    }

    /// Takes or leaves out one side of a chunk. Deciding again the same way takes the decision back.
    func decide(_ index: Int, mine side: Bool, take: Bool) {
        guard merge != nil else { return }
        sync()
        remember()
        resolution.decide(index, mine: side, take: take)
        rebuild()
        check()
        onChange?()
    }

    /// Takes one side's changes everywhere and leaves the other's out, so the result reads as that side's file.
    /// It only fills the result: the file stays in conflict until Mark Resolved, and ⌘Z brings the previous decisions back.
    func acceptAll(mine side: Bool) {
        guard merge != nil else { return }
        sync()
        remember()
        resolution.acceptAll(mine: side)
        rebuild()
        check()
        onChange?()
    }

    /// Decisions and folds go on the same undo stack as typing, so ⌘Z walks back through both in order.
    private func remember() {
        centerView.breakUndoCoalescing()
        let snapshot = (resolution, expanded)
        undo.registerUndo(withTarget: self) { editor in
            editor.sync()
            editor.remember()
            (editor.resolution, editor.expanded) = snapshot
            editor.rebuild()
            editor.check()
            editor.onChange?()
        }
    }

    private func unfold(_ key: Int) {
        sync()
        remember()
        expanded.insert(key)
        rebuild()
    }

    /// Reads what you typed back into the per unit copy.
    private func sync() {
        guard let storage = centerView.textStorage else { return }
        let string = storage.string as NSString
        for (item, range) in items {
            if case .unit(let unit) = item { resolution.edit(unit, to: string.substring(with: range)) }
        }
    }

    private static func text(_ lines: [String]) -> String { lines.map { $0 + "\n" }.joined() }

    // MARK: Building the columns

    private static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = rowHeight
        style.maximumLineHeight = rowHeight
        return style
    }

    /// Which units show. Folded: unchanged lines away from any change, and changes taken on their own away from conflicts.
    private func visibility() -> [Bool] {
        if showAll { return units.map { _ in true } }
        var visible = units.map { unit -> Bool in
            guard case .chunk(let index) = unit else { return false }
            return !(decisions[index].auto && !nearConflict[index])
        }
        let chunksShown = visible
        for (position, shown) in chunksShown.enumerated() where shown {
            for offset in 1...Self.context {
                for neighbor in [position - offset, position + offset] where units.indices.contains(neighbor) {
                    if case .line = units[neighbor] { visible[neighbor] = true }
                }
            }
        }
        // A fold of one line hides nothing worth a click, and an opened fold stays open.
        var position = 0
        while position < units.count {
            guard !visible[position] else { position += 1; continue }
            var end = position
            while end < units.count, !visible[end] { end += 1 }
            if end - position < 2 || expanded.contains(position) {
                for index in position..<end { visible[index] = true }
            }
            position = end
        }
        return visible
    }

    /// Counted on bytes: walking characters is slow on a long file, and reads "\r\n" as one character that isn't "\n".
    private func lineCount(_ text: String) -> Int { text.utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 } }

    private func rebuild(keepScroll: Bool = true) {
        guard let merge, let colors else { return }
        let visible = visibility()
        if keepScroll, patch(visible) { return }
        let origins = columns.map { $0.scroll.contentView.bounds.origin }
        let selection = centerView.selectedRange()
        let base = baseAttributes(colors)
        let foldAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: colors.muted, .paragraphStyle: Self.paragraph, .mergeFold: true,
        ]
        let mineText = NSMutableAttributedString(), centerText = NSMutableAttributedString(), otherText = NSMutableAttributedString()
        var mineNumbers: [Int?] = [], otherNumbers: [Int?] = [], centerNumbers: [Int?] = []
        var resultLine = 1
        items = []
        chunkItems = [:]
        sideRanges = [:]
        sideFolds = ([], [])
        blocks = []

        func append(_ string: String, to text: NSMutableAttributedString, _ attributes: [NSAttributedString.Key: Any]) -> NSRange {
            let range = NSRange(location: text.length, length: (string as NSString).length)
            text.append(NSAttributedString(string: string, attributes: attributes))
            return range
        }
        func startBlock() -> (Int, Int, Int) { (mineText.length, items.count, otherText.length) }
        func endBlock(_ start: (Int, Int, Int)) {
            blocks.append((NSRange(location: start.0, length: mineText.length - start.0), start.1..<items.count,
                           NSRange(location: start.2, length: otherText.length - start.2)))
        }

        var position = 0
        while position < units.count {
            if !visible[position] {
                var end = position
                while end < units.count, !visible[end] { end += 1 }
                let block = startBlock()
                var hiddenMine = 0, hiddenOther = 0, hiddenCenter = 0, autos = 0
                for unit in position..<end {
                    switch units[unit] {
                    case .line:
                        hiddenMine += 1
                        hiddenOther += 1
                    case .chunk(let index):
                        hiddenMine += merge.chunks[index].mine.count
                        hiddenOther += merge.chunks[index].other.count
                        if decisions[index].auto { autos += 1 }
                    }
                    hiddenCenter += lineCount(resolution.texts[unit])
                }
                let changes = autos == 0 ? "" : ", \(autos) auto-merged"
                sideFolds.mine.append((append("⋯ \(hiddenMine) lines\n", to: mineText, foldAttributes), position))
                sideFolds.other.append((append("⋯ \(hiddenOther) lines\n", to: otherText, foldAttributes), position))
                let range = append("⋯ \(hiddenCenter) lines\(changes)\n", to: centerText, foldAttributes)
                items.append((.fold(position..<end), range))
                mineNumbers.append(nil)
                otherNumbers.append(nil)
                centerNumbers.append(nil)
                resultLine += hiddenCenter
                endBlock(block)
                position = end
                continue
            }
            let block = startBlock()
            // Unchanged lines in a row scroll as one block.
            while position < units.count, visible[position], case .line(let line) = units[position] {
                _ = append(merge.base[line] + "\n", to: mineText, base)
                _ = append(merge.base[line] + "\n", to: otherText, base)
                let range = append(resolution.texts[position], to: centerText, base)
                items.append((.unit(position), range))
                mineNumbers.append(starts[position].mine + 1)
                otherNumbers.append(starts[position].other + 1)
                for _ in 0..<lineCount(resolution.texts[position]) {
                    centerNumbers.append(resultLine)
                    resultLine += 1
                }
                position += 1
            }
            if position < units.count, visible[position], case .chunk(let index) = units[position] {
                let chunk = merge.chunks[index]
                let mineRange = append(Self.text(merge.lines(chunk, mine: true)), to: mineText, base)
                let otherRange = append(Self.text(merge.lines(chunk, mine: false)), to: otherText, base)
                sideRanges[index] = (mineRange, otherRange)
                mineNumbers += chunk.mine.map { $0 + 1 }
                otherNumbers += chunk.other.map { $0 + 1 }
                let range = append(resolution.texts[position], to: centerText, base)
                chunkItems[index] = items.count
                items.append((.unit(position), range))
                for _ in 0..<lineCount(resolution.texts[position]) {
                    centerNumbers.append(resultLine)
                    resultLine += 1
                }
                position += 1
            }
            if items.count > block.1 { endBlock(block) }
        }

        applying = true
        mineView.textStorage?.setAttributedString(mineText)
        otherView.textStorage?.setAttributedString(otherText)
        centerView.textStorage?.setAttributedString(centerText)
        applying = false
        self.mineNumbers.numbers = mineNumbers
        self.otherNumbers.numbers = otherNumbers
        self.centerNumbers.numbers = centerNumbers
        mineView.folds = sideFolds.mine
        otherView.folds = sideFolds.other
        updateCenterFolds()
        highlight()
        updateBands()
        for view in columns { view.sizeToContent() }
        if keepScroll {
            for (view, origin) in zip(columns, origins) {
                view.scroll.contentView.scroll(to: origin)
                view.scroll.reflectScrolledClipView(view.scroll.contentView)
            }
            let length = centerView.textStorage?.length ?? 0
            centerView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
        redrawGutters()
        built = (visible, resolution)
    }

    /// Puts the units whose text changed in place in the result, when the folds stay as they are.
    /// The side columns don't change then, and laying out and coloring all three again is slow on a long file.
    /// Returns false when the columns need a full rebuild.
    private func patch(_ visible: [Bool]) -> Bool {
        guard let built, built.visible == visible, let storage = centerView.textStorage, let colors else { return false }
        // Fold labels count the lines and automatic changes they hide.
        for (unit, shown) in visible.enumerated() where !shown {
            guard resolution.texts[unit] == built.resolution.texts[unit] else { return false }
            if case .chunk(let index) = units[unit], resolution.decisions[index].auto != built.resolution.decisions[index].auto {
                return false
            }
        }
        let selection = centerView.selectedRange()
        let base = baseAttributes(colors)
        var delta = 0, changed: [NSRange] = []
        applying = true
        storage.beginEditing()
        for index in items.indices {
            items[index].range.location += delta
            guard case .unit(let unit) = items[index].item else { continue }
            let range = items[index].range, text = resolution.texts[unit]
            guard (storage.string as NSString).substring(with: range) != text else { continue }
            storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: base))
            let length = (text as NSString).length
            items[index].range.length = length
            delta += length - range.length
            changed.append(items[index].range)
        }
        // Colored in the same edit, since a second edit makes the layout start over from there.
        if let first = changed.first { recolor(from: first.location) }
        storage.endEditing()
        applying = false
        if !changed.isEmpty {
            renumberCenter()
            updateCenterFolds()
            centerView.sizeToContent()
            centerView.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
        }
        // The result's word marks follow its text, which just moved.
        if !changed.isEmpty { applyInlineHighlights(colors) }
        updateBands()
        redrawGutters()
        self.built = (visible, resolution)
        return true
    }

    private func baseAttributes(_ colors: MergeColors) -> [NSAttributedString.Key: Any] {
        let baseline = (Self.rowHeight - NSLayoutManager().defaultLineHeight(for: CodeText.font)) / 2
        return [.font: CodeText.font, .foregroundColor: colors.foreground, .paragraphStyle: Self.paragraph, .baselineOffset: baseline]
    }

    private func updateCenterFolds() {
        centerView.folds = items.compactMap { item, range in
            if case .fold(let units) = item { (range, units.lowerBound) } else { nil }
        }
    }

    /// Code colors on all three columns. Fold labels keep their muted color.
    private func highlight() {
        guard let colors else { return }
        for view in columns {
            guard let storage = view.textStorage else { continue }
            let small = storage.length <= 400_000
            CodeText.highlight(storage, small ? language : nil, syntax, plain: colors.foreground)
            storage.beginEditing()
            for (range, _) in view.folds { storage.addAttribute(.foregroundColor, value: colors.muted, range: range) }
            storage.endEditing()
        }
        applyInlineHighlights(colors)
    }

    /// Marks the words each shown chunk changed from the ancestor, a shade stronger than its band.
    /// Temporary attributes keep the marks out of the text, its undo and the typing attributes.
    private func applyInlineHighlights(_ colors: MergeColors) {
        guard let merge else { return }
        for view in columns {
            guard let layout = view.layoutManager, let length = view.textStorage?.length else { continue }
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        }
        func mark(_ view: MergeTextView, _ range: NSRange, _ lines: [String], against base: [String], _ tint: NSColor) {
            guard let layout = view.layoutManager, let length = view.textStorage?.length, NSMaxRange(range) <= length else { return }
            var start = range.location
            for (line, changes) in zip(lines, InlineDiff.changes(base: base, changed: lines)) {
                for change in changes {
                    layout.addTemporaryAttribute(.backgroundColor, value: tint.withAlphaComponent(0.3),
                                                 forCharacterRange: NSRange(location: start + change.lowerBound, length: change.count))
                }
                start += line.utf16.count + 1
            }
        }
        for (index, ranges) in sideRanges {
            let chunk = merge.chunks[index], base = merge.baseLines(chunk)
            guard !base.isEmpty else { continue }
            mark(mineView, ranges.mine, merge.lines(chunk, mine: true), against: base, colors.mine)
            mark(otherView, ranges.other, merge.lines(chunk, mine: false), against: base, colors.other)
            if let range = centerRange(index), let storage = centerView.textStorage, NSMaxRange(range) <= storage.length {
                var lines = (storage.string as NSString).substring(with: range).components(separatedBy: "\n")
                if lines.last == "" { lines.removeLast() }
                mark(centerView, range, lines, against: base, isDecided(index) ? colors.resolved : colors.pending)
            }
        }
    }

    /// Code colors on the result from `start` on, set only where they change.
    /// Coloring all of it makes the layout start over, which is slow on a long file. A comment opened in a chunk still colors the lines below.
    private func recolor(from start: Int) {
        guard let colors, let storage = centerView.textStorage, start < storage.length else { return }
        let kinds: [Syntax.Kind] = [.keyword, .string, .number, .comment]
        // Per UTF-16 unit, a place in `palette`: plain, then the token kinds, then fold labels.
        let palette = [colors.foreground] + kinds.map { syntax?.color($0) ?? colors.foreground } + [colors.muted]
        var wanted = [UInt8](repeating: 0, count: storage.length - start)
        if let language, syntax != nil, storage.length <= 400_000 {
            for token in Syntax.tokens(in: storage.string, language) where NSMaxRange(token.range) > start {
                let kind = UInt8(kinds.firstIndex(of: token.kind)! + 1)
                for at in max(token.range.location, start)..<NSMaxRange(token.range) { wanted[at - start] = kind }
            }
        }
        for case (.fold, let range) in items where NSMaxRange(range) > start {
            for at in max(range.location, start)..<NSMaxRange(range) { wanted[at - start] = UInt8(palette.count - 1) }
        }
        var fixes: [(NSRange, NSColor)] = []
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: start, length: storage.length - start)) { value, run, _ in
            var at = run.location
            while at < NSMaxRange(run) {
                var end = at + 1
                while end < NSMaxRange(run), wanted[end - start] == wanted[at - start] { end += 1 }
                let color = palette[Int(wanted[at - start])]
                if value as? NSColor != color { fixes.append((NSRange(location: at, length: end - at), color)) }
                at = end
            }
        }
        for (range, color) in fixes { storage.addAttribute(.foregroundColor, value: color, range: range) }
    }

    private func highlightSoon() {
        pendingHighlight?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.highlight()
            self?.check()
            self?.onChange?()
        }
        pendingHighlight = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Bands and waves

    enum Look {
        case waiting, taken, dropped
    }

    /// How one side of a chunk looks: still to decide, taken into the result, or left out.
    func look(_ index: Int, mine side: Bool) -> Look? {
        let sides = sides(index)
        guard side ? sides.mine : sides.other else { return nil }
        let decision = decisions[index]
        if decision.edited { return .taken }
        switch side ? decision.mine : decision.other {
        case true?: return .taken
        case false?: return .dropped
        case nil: return .waiting
        }
    }

    func band(for look: Look, mine side: Bool) -> MergeBand.Style {
        guard let colors else { return MergeBand.Style(fill: .clear, edge: .clear, dashed: false) }
        let tint = side ? colors.mine : colors.other
        switch look {
        case .waiting: return MergeBand.Style(fill: tint.withAlphaComponent(0.14), edge: tint.withAlphaComponent(0.6), dashed: false)
        case .taken: return MergeBand.Style(fill: tint.withAlphaComponent(0.05), edge: tint.withAlphaComponent(0.25), dashed: false)
        case .dropped: return MergeBand.Style(fill: colors.dropped.withAlphaComponent(0.04),
                                              edge: colors.dropped.withAlphaComponent(0.35), dashed: true)
        }
    }

    private func centerStyle(_ index: Int) -> MergeBand.Style {
        guard let colors else { return MergeBand.Style(fill: .clear, edge: .clear, dashed: false) }
        let decision = decisions[index]
        let decided = isDecided(index), nothingTaken = decision.order.isEmpty && !decision.edited
        let color = !decided ? colors.pending : nothingTaken ? colors.foreground : colors.resolved
        let (fill, edge): (CGFloat, CGFloat) = decided && nothingTaken ? (0.04, 0.18) : (0.09, 0.5)
        // The change the caret is in stands out, so you can tell where ⌥↓ and ⌥↑ took you.
        let lit = index == current
        return MergeBand.Style(fill: color.withAlphaComponent(lit ? fill * 2 : fill), edge: color.withAlphaComponent(lit ? 1 : edge),
                               dashed: decided && !nothingTaken && decision.auto && !decision.edited, bar: lit)
    }

    /// The shown change the caret is in. An empty one holds the caret at its start.
    private func chunk(at caret: Int) -> Int? {
        visibleChunks.first { index in
            guard let range = centerRange(index) else { return false }
            return range.length == 0 ? caret == range.location : NSLocationInRange(caret, range)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applying, chunk(at: centerView.selectedRange().location) != current else { return }
        updateBands()
    }

    private func updateBands() {
        current = chunk(at: centerView.selectedRange().location)
        var mine: [MergeBand] = [], center: [MergeBand] = [], other: [MergeBand] = []
        for (index, ranges) in sideRanges {
            if let look = look(index, mine: true) { mine.append(MergeBand(range: ranges.mine, style: band(for: look, mine: true))) }
            if let look = look(index, mine: false) { other.append(MergeBand(range: ranges.other, style: band(for: look, mine: false))) }
            if let range = centerRange(index) { center.append(MergeBand(range: range, style: centerStyle(index))) }
        }
        mineView.bands = mine
        otherView.bands = other
        centerView.bands = center
        updateMarkers()
    }

    // MARK: Markers and warnings

    /// Where each unit starts in the result, from 1, and how many lines the result has.
    private func resultStarts() -> (starts: [Int], total: Int) {
        var starts: [Int] = []
        var line = 1
        for text in resolution.texts {
            starts.append(line)
            line += lineCount(text)
        }
        return (starts, max(line - 1, 1))
    }

    /// One mark per change and per warning, placed by its line in the whole result, folds included.
    private func updateMarkers() {
        guard let colors, merge != nil else { return }
        sync()
        let (starts, total) = resultStarts()
        var marks: [MergeMarkers.Mark] = []
        for (unit, kind) in units.enumerated() {
            guard case .chunk(let index) = kind else { continue }
            let decision = decisions[index]
            let color = !isDecided(index) ? colors.pending : colors.resolved
            marks.append(.init(fraction: CGFloat(starts[unit] - 1) / CGFloat(total), color: color,
                               outline: decision.auto, line: starts[unit]))
        }
        for warning in warnings {
            marks.append(.init(fraction: CGFloat(warning.line - 1) / CGFloat(total), color: colors.dropped, outline: false, line: warning.line))
        }
        markers.marks = marks
    }

    /// Looks for names the result dropped but still uses, against all three versions.
    /// Off the main thread, since it reads every line of a long file. Only the latest check is kept.
    private func check() {
        guard merge != nil else { return }
        sync()
        let result = resolution.texts.joined(), versions = versionTexts
        checks += 1
        let check = checks
        DispatchQueue.global(qos: .userInitiated).async {
            let warnings = Merge.undeclared(in: result, versions: versions)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.checks == check else { return }
                self.warnings = warnings
                self.updateMarkers()
                self.onChange?()
            }
        }
    }

    /// Scrolls the result to a line, opening the fold it is in first.
    func reveal(resultLine: Int) {
        sync()
        let (starts, _) = resultStarts()
        guard let unit = starts.lastIndex(where: { $0 <= resultLine }) else { return }
        if !items.contains(where: { $0.item == .unit(unit) }),
           let fold = items.first(where: { if case .fold(let units) = $0.item { units.contains(unit) } else { false } }),
           case .fold(let units) = fold.item {
            remember()
            expanded.insert(units.lowerBound)
            rebuild()
        }
        guard let range = items.first(where: { $0.item == .unit(unit) })?.range, let storage = centerView.textStorage else { return }
        let string = storage.string as NSString
        var location = range.location
        for _ in 0..<(resultLine - starts[unit]) where location < NSMaxRange(range) {
            location = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
        }
        centerView.setSelectedRange(NSRange(location: location, length: 0))
        window?.makeFirstResponder(centerView)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let (top, _) = self.centerView.span(NSRange(location: location, length: 0))
            self.scrollCenter(to: top - 80)
        }
    }

    func centerRange(_ index: Int) -> NSRange? {
        chunkItems[index].map { items[$0].range }
    }

    func sideRange(_ index: Int, mine: Bool) -> NSRange? {
        sideRanges[index].map { mine ? $0.mine : $0.other }
    }

    var visibleChunks: [Int] { sideRanges.keys.sorted() }

    /// The top and bottom of a range of text, in `view`'s coordinates. An empty range is a line between two rows.
    func span(_ range: NSRange, in column: Int, to view: NSView) -> (top: CGFloat, bottom: CGFloat) {
        let text = columns[column]
        let (top, bottom) = text.span(range)
        let a = text.convert(NSPoint(x: 0, y: top), to: view).y
        let b = text.convert(NSPoint(x: 0, y: bottom), to: view).y
        return (min(a, b), max(a, b))
    }

    private func redrawGutters() {
        leftGutter.needsDisplay = true
        rightGutter.needsDisplay = true
        for numbers in [mineNumbers, centerNumbers, otherNumbers] { numbers.needsDisplay = true }
        markers.needsDisplay = true
    }

    // MARK: Typing

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        // Fold labels aren't part of the file. Typing right before or after one is fine.
        !items.contains { item, folded in
            guard case .fold = item else { return false }
            if range.length == 0 { return range.location > folded.location && range.location < NSMaxRange(folded) }
            return NSIntersectionRange(range, folded).length > 0
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    /// Typed or pasted text takes the font, row height and baseline of the lines around it.
    /// Without this it falls back to the view's defaults and sits lower than its neighbors.
    func textStorage(_ storage: NSTextStorage, willProcessEditing mask: NSTextStorageEditActions, range edited: NSRange,
                     changeInLength delta: Int) {
        guard mask.contains(.editedCharacters), !applying, edited.length > 0, let colors, storage === centerView.textStorage else { return }
        storage.addAttributes(baseAttributes(colors), range: edited)
    }

    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range edited: NSRange,
                     changeInLength delta: Int) {
        guard mask.contains(.editedCharacters), !applying, storage === centerView.textStorage else { return }
        let a = edited.location, b = edited.location + edited.length - delta, inserted = edited.length
        func isChunk(_ item: Item) -> Bool {
            if case .unit(let unit) = item, case .chunk = units[unit] { return true }
            return false
        }
        // The new text goes to an empty chunk right there, else to the unit it was typed in, never to a fold label.
        var receiver = items.firstIndex { $0.range.length == 0 && $0.range.location == a && isChunk($0.item) }
            ?? items.firstIndex { a >= $0.range.location && a < NSMaxRange($0.range) }
            ?? items.count - 1
        if case .fold = items[receiver].item, receiver > 0 { receiver -= 1 }
        for index in items.indices {
            let start = items[index].range.location, end = NSMaxRange(items[index].range)
            var newStart = start <= a ? start : start >= b ? start + delta : a + inserted
            var newEnd = end <= a ? end : end >= b ? end + delta : a + inserted
            if index < receiver {
                newEnd = min(newEnd, a)
                newStart = min(newStart, newEnd)
            } else if index == receiver {
                newStart = min(newStart, a)
                newEnd = max(newEnd, a + inserted)
            } else {
                newStart = max(newStart, a + inserted)
                newEnd = max(newEnd, newStart)
            }
            items[index].range = NSRange(location: newStart, length: newEnd - newStart)
        }
        // Typing can't tell an edit from its undo, so whether a chunk is edited comes from its text, not from the keystroke.
        let changed = refreshEdited()
        updateCenterFolds()
        // Line numbers and bands are read once the layout has caught up with the edit.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renumberCenter()
            self.updateBands()
            self.centerView.needsDisplay = true
            self.redrawGutters()
            if changed { self.onChange?() }
        }
        highlightSoon()
    }

    /// Reads the chunks' text back after typing. Returns whether any chunk became edited, or stopped being.
    private func refreshEdited() -> Bool {
        guard let storage = centerView.textStorage else { return false }
        let string = storage.string as NSString
        var changed = false
        for (item, range) in items {
            guard case .unit(let unit) = item, case .chunk = units[unit] else { continue }
            if resolution.edit(unit, to: string.substring(with: range)) { changed = true }
        }
        return changed
    }

    private func renumberCenter() {
        guard let storage = centerView.textStorage else { return }
        let string = storage.string as NSString
        var numbers: [Int?] = []
        var line = 1
        for (item, range) in items {
            switch item {
            case .fold(let folded):
                numbers.append(nil)
                line += folded.reduce(0) { $0 + lineCount(resolution.texts[$1]) }
            case .unit:
                let count = lineCount(string.substring(with: range))
                for _ in 0..<count {
                    numbers.append(line)
                    line += 1
                }
            }
        }
        centerNumbers.numbers = numbers
    }

    // MARK: Moving around

    /// Scrolls the center to the next chunk still waiting for a decision.
    func jump(forward: Bool, from current: Int? = nil) {
        let open = visibleChunks.filter { !isDecided($0) }
        guard !open.isEmpty else { return }
        let caret = centerView.selectedRange().location
        let here = current ?? (visibleChunks.last { (centerRange($0)?.location ?? 0) <= caret } ?? -1)
        let target = forward ? (open.first { $0 > here } ?? open[0]) : (open.last { $0 < here } ?? open[open.count - 1])
        guard let range = centerRange(target) else { return }
        centerView.setSelectedRange(NSRange(location: range.location, length: 0))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let (top, _) = self.centerView.span(range)
            self.scrollCenter(to: top - 80)
        }
    }

    /// Not past the end, so nothing moves when the whole file fits in the view.
    private func scrollCenter(to y: CGFloat) {
        let clip = centerView.scroll.contentView
        let limit = max(0, centerView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), limit)))
        centerView.scroll.reflectScrolledClipView(clip)
    }

    /// Keeps the other two columns level with the one you scrolled, block by block, since their lines don't match one to one.
    private func scrolled(_ source: MergeTextView) {
        redrawGutters()
        guard !syncing, !blocks.isEmpty, let column = columns.firstIndex(of: source) else { return }
        syncing = true
        defer { syncing = false }
        let y = source.scroll.contentView.bounds.minY
        let anchors = blocks.map { block in
            (columns[0].span(block.mine).top, centerTop(block.items), columns[2].span(block.other).top)
        }
        func value(_ anchor: (CGFloat, CGFloat, CGFloat), _ column: Int) -> CGFloat {
            column == 0 ? anchor.0 : column == 1 ? anchor.1 : anchor.2
        }
        var k = 0
        while k + 1 < anchors.count, value(anchors[k + 1], column) <= y { k += 1 }
        for (index, target) in columns.enumerated() where index != column {
            let from0 = value(anchors[k], column), to0 = value(anchors[k], index)
            let from1 = k + 1 < anchors.count ? value(anchors[k + 1], column) : from0 + 1
            let to1 = k + 1 < anchors.count ? value(anchors[k + 1], index) : to0 + 1
            let fraction = from1 > from0 ? (y - from0) / (from1 - from0) : 0
            // Above the first block, as in the margin at the top, the columns move together line for line.
            // So do they in the last block, which has no block after it to measure against.
            let together = (y < from0 && k == 0) || k + 1 == anchors.count
            let mapped = together ? to0 + (y - from0) : to0 + (to1 - to0) * min(max(fraction, 0), 1)
            let targetY = max(0, mapped)
            target.scroll.contentView.scroll(to: NSPoint(x: target.scroll.contentView.bounds.minX, y: targetY))
            target.scroll.reflectScrolledClipView(target.scroll.contentView)
        }
    }

    private func centerTop(_ span: Range<Int>) -> CGFloat {
        guard let first = span.first, items.indices.contains(first) else { return 0 }
        return centerView.span(NSRange(location: items[first].range.location, length: 0)).top
    }

    // MARK: Layout

    /// Where yours, the result's line numbers and the incoming column start, for the titles above them.
    static func columnStarts(width: CGFloat) -> (mine: CGFloat, center: CGFloat, other: CGFloat, column: CGFloat) {
        let column = max(0, (width - 2 * gutterWidth - MergeNumbers.width - MergeMarkers.width) / 3)
        return (0, column + gutterWidth, 2 * column + 2 * gutterWidth + MergeNumbers.width, column)
    }

    override func layout() {
        super.layout()
        let numbers = MergeNumbers.width
        let starts = Self.columnStarts(width: bounds.width), column = starts.column
        mineView.scroll.frame = NSRect(x: starts.mine, y: 0, width: column, height: bounds.height)
        leftGutter.frame = NSRect(x: column, y: 0, width: Self.gutterWidth, height: bounds.height)
        mineNumbers.frame = NSRect(x: column + Self.buttonsWidth, y: 0, width: numbers, height: bounds.height)
        centerNumbers.frame = NSRect(x: starts.center, y: 0, width: numbers, height: bounds.height)
        centerView.scroll.frame = NSRect(x: starts.center + numbers, y: 0, width: column, height: bounds.height)
        let right = starts.center + numbers + column
        rightGutter.frame = NSRect(x: right, y: 0, width: Self.gutterWidth, height: bounds.height)
        otherNumbers.frame = NSRect(x: right + Self.waveWidth, y: 0, width: numbers, height: bounds.height)
        otherView.scroll.frame = NSRect(x: starts.other, y: 0, width: column, height: bounds.height)
        markers.frame = NSRect(x: starts.other + column, y: 0, width: MergeMarkers.width, height: bounds.height)
        for view in columns { view.sizeToContent() }
        redrawGutters()
    }
}

extension NSAttributedString.Key {
    static let mergeFold = NSAttributedString.Key("farol.mergeFold")
}

/// A tinted stretch of rows behind a chunk, with a line above and below.
struct MergeBand {
    struct Style {
        let fill: NSColor
        let edge: NSColor
        let dashed: Bool
        /// A thick mark on the left edge, for the change you are on.
        var bar = false
    }

    let range: NSRange
    let style: Style
}

/// One column's text. Draws the bands under the text, and opens a fold when its label is clicked.
final class MergeTextView: NSTextView {
    let scroll = NSScrollView()
    var bands: [MergeBand] = [] { didSet { needsDisplay = true } }
    var folds: [(NSRange, Int)] = []
    var onFoldClick: ((Int) -> Void)?
    var onEscape: (() -> Void)?
    var onJump: ((Bool) -> Void)?

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        CodeText.configure(self)
        isHorizontallyResizable = true
        isVerticallyResizable = true
        autoresizingMask = []
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = self
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.contentView.postsBoundsChangedNotifications = true
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func sizeToContent() {
        minSize = scroll.contentSize
        if let layout = layoutManager, let container = textContainer {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            setFrameSize(NSSize(width: max(scroll.contentSize.width, used.width + 40),
                                height: max(scroll.contentSize.height, used.height + textContainerInset.height * 2 + 60)))
        }
    }

    /// Top and bottom of a range in this view. An empty range sits on the top edge of the row it comes before.
    func span(_ range: NSRange) -> (top: CGFloat, bottom: CGFloat) {
        guard let layout = layoutManager, let storage = textStorage else { return (0, 0) }
        let origin = textContainerOrigin.y
        func top(ofCharacter index: Int) -> CGFloat {
            if index >= storage.length {
                let extra = layout.extraLineFragmentRect
                if extra.height > 0 { return extra.minY + origin }
                guard storage.length > 0 else { return origin }
                let glyph = layout.glyphIndexForCharacter(at: storage.length - 1)
                return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).maxY + origin
            }
            let glyph = layout.glyphIndexForCharacter(at: index)
            return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + origin
        }
        guard range.length > 0 else {
            let y = top(ofCharacter: range.location)
            return (y, y)
        }
        let last = layout.glyphIndexForCharacter(at: NSMaxRange(range) - 1)
        return (top(ofCharacter: range.location), layout.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).maxY + origin)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        for band in bands {
            let (top, bottom) = span(band.range)
            guard bottom >= rect.minY - 2, top <= rect.maxY + 2 else { continue }
            let area = NSRect(x: 0, y: top, width: bounds.width, height: bottom - top)
            band.style.fill.setFill()
            area.fill()
            if band.style.bar {
                band.style.edge.setFill()
                NSRect(x: 0, y: top, width: 2, height: bottom - top).fill()
            }
            band.style.edge.setStroke()
            for y in [top + 0.5, bottom - 0.5] {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 0, y: y))
                line.line(to: NSPoint(x: bounds.width, y: y))
                line.lineWidth = 1
                if band.style.dashed { line.setLineDash([3, 3], count: 2, phase: 0) }
                line.stroke()
                if top == bottom { break }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let fold = folds.first(where: { NSLocationInRange(index, $0.0) }) {
            return onFoldClick?(fold.1) ?? ()
        }
        super.mouseDown(with: event)
    }

    /// Escape goes back to the terminal instead of offering completions.
    override func complete(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .option, let onJump {
            switch event.keyCode {
            case 125: return onJump(true)
            case 126: return onJump(false)
            default: break
            }
        }
        super.keyDown(with: event)
    }

    /// A new line starts at the same indent as the one before.
    override func insertNewline(_ sender: Any?) {
        let string = self.string as NSString
        let line = string.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let indent = string.substring(with: line).prefix { $0 == " " || $0 == "\t" }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(String(indent), replacementRange: selectedRange()) }
    }
}

/// The strip on the right edge: where the changes and warnings are in the whole result, folded or not.
/// Click a mark to go there.
final class MergeMarkers: NSView {
    static let width: CGFloat = 12

    struct Mark {
        let fraction: CGFloat
        let color: NSColor
        /// Changes taken on their own are drawn hollow, the ones that needed you filled.
        let outline: Bool
        let line: Int
    }

    var marks: [Mark] = [] {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var onClick: ((Int) -> Void)?
    weak var textView: MergeTextView?

    override var isFlipped: Bool { true }

    /// A map of the file only helps when the file is longer than the view. When it all fits, the marks would sit far from their lines.
    private var scrolls: Bool {
        guard let textView else { return true }
        return textView.frame.height > textView.scroll.contentSize.height
    }

    private func rect(_ mark: Mark) -> NSRect {
        NSRect(x: 2, y: 4 + mark.fraction * max(bounds.height - 12, 0), width: bounds.width - 4, height: 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard scrolls else { return }
        for mark in marks {
            let path = NSBezierPath(roundedRect: rect(mark), xRadius: 1, yRadius: 1)
            if mark.outline {
                mark.color.withAlphaComponent(0.25).setFill()
                path.fill()
                mark.color.setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                mark.color.setFill()
                path.fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard scrolls else { return }
        let point = convert(event.locationInWindow, from: nil)
        let hit = marks.min { abs(rect($0).midY - point.y) < abs(rect($1).midY - point.y) }
        if let hit, abs(rect(hit).midY - point.y) < 8 { onClick?(hit.line) }
    }

    override func resetCursorRects() {
        guard scrolls else { return }
        for mark in marks { addCursorRect(rect(mark).insetBy(dx: -2, dy: -6), cursor: .pointingHand) }
    }
}

/// Line numbers for one column. They come from the file, not the rows on screen, since folds hide lines.
final class MergeNumbers: NSView {
    static let width: CGFloat = 44
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    weak var textView: MergeTextView?
    var numbers: [Int?] = [] { didSet { needsDisplay = true } }
    var alignRight = false
    var colors = (background: NSColor.black, text: NSColor.gray) { didSet { needsDisplay = true } }
    var fillsBackground = true

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if fillsBackground {
            colors.background.setFill()
            bounds.fill()
        }
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0 else { return }
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: colors.text]
        let string = storage.string as NSString
        // Rows above the visible ones, counted once per draw. Cheap next to laying the text out.
        let firstCharacter = layout.characterIndexForGlyph(at: glyphs.location)
        var row = 0
        var index = 0
        while index < firstCharacter {
            index = NSMaxRange(string.lineRange(for: NSRange(location: index, length: 0)))
            if index <= firstCharacter { row += 1 }
        }
        index = string.lineRange(for: NSRange(location: firstCharacter, length: 0)).location
        while index < string.length {
            let glyph = layout.glyphIndexForCharacter(at: index)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = textView.convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), to: self).y
            if y > bounds.height { break }
            if row < numbers.count, let number = numbers[row] {
                let label = "\(number)" as NSString
                let size = label.size(withAttributes: attributes)
                let x = alignRight ? 8 : bounds.width - size.width - 8
                label.draw(at: NSPoint(x: x, y: y + (fragment.height - size.height) / 2), withAttributes: attributes)
            }
            index = NSMaxRange(string.lineRange(for: NSRange(location: index, length: 0)))
            row += 1
        }
    }
}

/// The space between a side and the result, laid out like IntelliJ's.
/// Yours: the buttons and your line numbers on the change's band, then a wave to its place in the result.
/// Incoming: the wave, then its line numbers and buttons. The numbers are a view on top, so they show over the band.
final class MergeGutter: NSView {
    weak var editor: MergeEditor?
    let mine: Bool
    /// The flat part next to the side, holding its buttons and line numbers.
    var strip: CGFloat = 0
    private var buttons: [(rect: NSRect, chunk: Int, take: Bool, tip: String)] = []
    /// Where the mouse is, to light the button under it like the icon buttons elsewhere.
    private var mouse: NSPoint?

    init(mine: Bool) {
        self.mine = mine
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let editor else { return }
        buttons = []
        let side = mine ? 0 : 2
        let w = bounds.width
        // The wave runs between `a` and `b`, the strip covers the rest.
        let (a, b) = mine ? (strip, w) : (0, w - strip)
        for index in editor.visibleChunks {
            guard let look = editor.look(index, mine: mine), let sideRange = editor.sideRange(index, mine: mine),
                  let centerRange = editor.centerRange(index) else { continue }
            let s = editor.span(sideRange, in: side, to: self)
            let c = editor.span(centerRange, in: 1, to: self)
            guard max(s.bottom, c.bottom) >= -20, min(s.top, c.top) <= bounds.height + 20 else { continue }
            // Left and right ends of the wave: the side's edge is where its column is.
            let (l0, l1, r0, r1) = mine ? (s.top, s.bottom, c.top, c.bottom) : (c.top, c.bottom, s.top, s.bottom)
            let m = (a + b) / 2
            let style = editor.band(for: look, mine: mine)
            let flat = mine ? NSRect(x: 0, y: s.top, width: strip, height: s.bottom - s.top)
                : NSRect(x: w - strip, y: s.top, width: strip, height: s.bottom - s.top)
            let shape = NSBezierPath()
            shape.move(to: NSPoint(x: a, y: l0))
            shape.curve(to: NSPoint(x: b, y: r0), controlPoint1: NSPoint(x: m, y: l0), controlPoint2: NSPoint(x: m, y: r0))
            shape.line(to: NSPoint(x: b, y: r1))
            shape.curve(to: NSPoint(x: a, y: l1), controlPoint1: NSPoint(x: m, y: r1), controlPoint2: NSPoint(x: m, y: l1))
            shape.close()
            style.fill.setFill()
            shape.fill()
            flat.fill()
            style.edge.setStroke()
            for (top, start, end) in [(true, l0 + 0.5, r0 + 0.5), (false, l1 - 0.5, r1 - 0.5)] {
                let edge = NSBezierPath()
                let y = top ? s.top + 0.5 : s.bottom - 0.5
                if mine {
                    edge.move(to: NSPoint(x: 0, y: y))
                    edge.line(to: NSPoint(x: a, y: start))
                } else {
                    edge.move(to: NSPoint(x: a, y: start))
                }
                edge.curve(to: NSPoint(x: b, y: end), controlPoint1: NSPoint(x: m, y: start), controlPoint2: NSPoint(x: m, y: end))
                if !mine { edge.line(to: NSPoint(x: w, y: y)) }
                edge.lineWidth = 1
                if style.dashed { edge.setLineDash([3, 3], count: 2, phase: 0) }
                edge.stroke()
            }
            drawButtons(index, look: look, at: (s.top + s.bottom) / 2)
        }
    }

    /// ✕ then » for yours, « then ✕ for the incoming side, so the arrow always points at the result.
    /// They sit at the outer end of the strip, by the code. Once decided, a single mark is left, and clicking it takes the decision back.
    private func drawButtons(_ index: Int, look: MergeEditor.Look, at y: CGFloat) {
        let size = NSSize(width: 20, height: 18)
        let top = y - size.height / 2
        let area = mine ? NSRect(x: 0, y: top, width: MergeEditor.buttonsWidth, height: size.height)
            : NSRect(x: bounds.width - MergeEditor.buttonsWidth, y: top, width: MergeEditor.buttonsWidth, height: size.height)
        let tint = editor?.band(for: .waiting, mine: mine).edge.withAlphaComponent(1) ?? .labelColor
        let middle = NSRect(origin: NSPoint(x: area.midX - size.width / 2, y: top), size: size)
        if editor?.decisions[index].edited == true {
            draw("pencil", in: middle, color: .secondaryLabelColor)
            return
        }
        switch look {
        case .waiting:
            let first = NSRect(origin: NSPoint(x: area.minX + 1, y: top), size: size)
            let second = NSRect(origin: NSPoint(x: area.maxX - size.width - 1, y: top), size: size)
            let (cross, arrow) = mine ? (first, second) : (second, first)
            button(cross, "xmark", index, take: false, tip: "Leave this change out")
            button(arrow, mine ? "chevron.right.2" : "chevron.left.2", index, take: true, tip: "Take this change into the result", color: tint)
        case .taken:
            button(middle, "checkmark", index, take: true, tip: "Taken. Click to decide again")
        case .dropped:
            button(middle, "xmark", index, take: false, tip: "Left out. Click to decide again")
        }
    }

    /// Gray until the mouse is on it, unless it has a color of its own.
    private func button(_ rect: NSRect, _ symbol: String, _ chunk: Int, take: Bool, tip: String, color: NSColor? = nil) {
        let lit = mouse.map(rect.insetBy(dx: -2, dy: -2).contains) ?? false
        if lit {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        }
        draw(symbol, in: rect, color: color ?? (lit ? .labelColor : .secondaryLabelColor))
        buttons.append((rect, chunk, take, tip))
    }

    private func draw(_ symbol: String, in rect: NSRect, color: NSColor) {
        let look = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(look) else { return }
        let size = image.size
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func button(at point: NSPoint?) -> (rect: NSRect, chunk: Int, take: Bool, tip: String)? {
        point.flatMap { point in buttons.first { $0.rect.insetBy(dx: -2, dy: -2).contains(point) } }
    }

    override func mouseMoved(with event: NSEvent) { hover(convert(event.locationInWindow, from: nil)) }

    override func mouseExited(with event: NSEvent) { hover(nil) }

    private func hover(_ point: NSPoint?) {
        let before = button(at: mouse), after = button(at: point)
        mouse = point
        guard before?.rect != after?.rect else { return }
        needsDisplay = true
        if let after, let window {
            HoverTip.shared.show(after.tip, below: window.convertToScreen(convert(after.rect, to: nil)), in: window)
        } else {
            HoverTip.shared.hide()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let hit = button(at: convert(event.locationInWindow, from: nil)) else { return }
        HoverTip.shared.hide()
        editor?.decide(hit.chunk, mine: mine, take: hit.take)
    }

    override func resetCursorRects() {
        for button in buttons { addCursorRect(button.rect, cursor: .pointingHand) }
    }
}
