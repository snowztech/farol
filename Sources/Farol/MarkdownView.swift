import AppKit
import FarolCore

/// A Markdown file as it reads: headings, lists, code and links drawn natively, in the theme's colors.
/// Read only, but selectable and searchable with ⌘F like the source.
final class MarkdownView: NSScrollView {
    let text = MarkdownTextView()
    /// Opens a file a relative link points to, in the file pane.
    var onOpenFile: ((String) -> Void)?

    private var colors = MarkdownColors(background: .textBackgroundColor, foreground: .textColor, syntax: nil)
    private var source = ""
    private var path = ""

    init() {
        super.init(frame: .zero)
        documentView = text
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        text.isEditable = false
        text.isSelectable = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.textContainerInset = NSSize(width: 18, height: 16)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        text.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Renders the file at `path`. Another file starts at the top, the same one keeps its place.
    func show(_ source: String, path: String) {
        guard source != self.source || path != self.path || text.textStorage?.length == 0 else { return }
        let sameFile = path == self.path
        self.source = source
        self.path = path
        render()
        if !sameFile { text.scroll(.zero) }
    }

    func apply(background: NSColor, foreground: NSColor, syntax: SyntaxColors?) {
        let colors = MarkdownColors(background: background, foreground: foreground, syntax: syntax)
        backgroundColor = background
        text.backgroundColor = background
        text.selectedTextAttributes = [.backgroundColor: background.mixed(with: foreground, 0.22)]
        guard colors != self.colors else { return }
        self.colors = colors
        render()
    }

    /// Keeps the reading position, so an agent rewriting the file doesn't send you back to the top.
    private func render() {
        let origin = contentView.bounds.origin
        // Relative links start from the file's folder.
        var renderer = MarkdownRenderer(colors: colors, folder: (path as NSString).deletingLastPathComponent)
        renderer.render(Markdown.blocks(in: source), indent: 0)
        text.textStorage?.setAttributedString(renderer.finished())
        text.markdownColors = colors
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

extension MarkdownView: NSTextViewDelegate {
    /// A link to a text file in the repo opens next to the terminal, like any file. The rest goes to the browser or its app.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.isFileURL else { return false }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue,
              let onOpenFile else { return false }
        onOpenFile(url.path)
        return true
    }
}

struct MarkdownColors: Equatable {
    let background: NSColor
    let foreground: NSColor
    let muted: NSColor
    let link: NSColor
    let code: NSColor
    /// Behind code blocks and inline code.
    let codeBackground: NSColor
    let line: NSColor

    init(background: NSColor, foreground: NSColor, syntax: SyntaxColors?) {
        self.background = background
        self.foreground = foreground
        muted = background.mixed(with: foreground, 0.6)
        link = syntax?.keyword ?? foreground
        code = syntax?.string ?? foreground
        codeBackground = background.mixed(with: foreground, 0.07)
        line = background.mixed(with: foreground, 0.2)
    }
}

private extension NSAttributedString.Key {
    /// Marks a code block's lines, so their background spans the width.
    static let markdownCode = NSAttributedString.Key("farol.markdownCode")
    /// A rule's line, drawn across the width.
    static let markdownRule = NSAttributedString.Key("farol.markdownRule")
    /// How many quotes a line is in, for the bars on its left.
    static let markdownQuote = NSAttributedString.Key("farol.markdownQuote")
}

/// Builds the attributed text, block by block. Spacing goes after each block, so the last one can drop it.
private struct MarkdownRenderer {
    let colors: MarkdownColors
    let folder: String
    private let output = NSMutableAttributedString()
    private var quote = 0

    private static let size: CGFloat = 13.5
    private static let step: CGFloat = 22
    private static let quoteStep: CGFloat = 16
    private static let gap: CGFloat = 10

    init(colors: MarkdownColors, folder: String) {
        self.colors = colors
        self.folder = folder
    }

    func finished() -> NSAttributedString {
        // The last block's newline would leave an empty line at the bottom.
        if output.string.hasSuffix("\n") { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
        return output
    }

    /// `marker` goes before the first block, for a list item.
    mutating func render(_ blocks: [Markdown.Block], indent: CGFloat, marker: String? = nil, tight: Bool = false) {
        var marker = marker
        for block in blocks {
            let left = indent + CGFloat(quote) * Self.quoteStep
            switch block {
            case .heading(let level, let text):
                let sizes: [CGFloat] = [22, 18, 15.5, 14, 13.5, 13.5]
                let font = NSFont.systemFont(ofSize: sizes[level - 1], weight: level <= 2 ? .bold : .semibold)
                let style = paragraph(left: left, marker: marker)
                // Space above a heading sets it apart from what comes before, except at the top.
                style.paragraphSpacingBefore = output.length == 0 ? 0 : level <= 2 ? 12 : 8
                style.paragraphSpacing = 6
                append(markerText(&marker, font: font), inline(text, font: font, color: colors.foreground), style: style)
            case .paragraph(let text):
                let font = NSFont.systemFont(ofSize: Self.size)
                let style = paragraph(left: left, marker: marker)
                style.paragraphSpacing = tight ? 3 : Self.gap
                style.lineSpacing = 2
                append(markerText(&marker, font: font), inline(text, font: font, color: quote > 0 ? colors.muted : colors.foreground),
                       style: style)
            case .code(_, let code):
                if let pending = markerText(&marker, font: .systemFont(ofSize: Self.size)) {
                    append(pending, NSAttributedString(), style: paragraph(left: left, marker: ""))
                }
                let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                let lines = code.components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let style = paragraph(left: left + 12, marker: nil)
                    style.tailIndent = -12
                    // The background reaches past the text, so the block needs room around it.
                    if index == 0 { style.paragraphSpacingBefore = 8 }
                    if index == lines.count - 1 { style.paragraphSpacing = Self.gap + 8 }
                    let text = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: colors.foreground])
                    append(nil, text, style: style, extra: [.markdownCode: true])
                }
            case .quote(let blocks):
                quote += 1
                render(blocks, indent: indent, marker: marker, tight: tight)
                marker = nil
                quote -= 1
                spaceAfter(Self.gap)
            case .list(let ordered, let start, let items):
                // A list whose items are one short line each reads best close together.
                let tight = items.allSatisfy { $0.blocks.count <= 1 }
                if let pending = markerText(&marker, font: .systemFont(ofSize: Self.size)) {
                    append(pending, NSAttributedString(), style: paragraph(left: left, marker: ""))
                }
                for (index, item) in items.enumerated() {
                    let bullet = switch item.checked {
                    case true?: "☑"
                    case false?: "☐"
                    case nil: ordered ? "\(start + index)." : indent == 0 ? "•" : "◦"
                    }
                    render(item.blocks.isEmpty ? [.paragraph("")] : item.blocks, indent: indent + Self.step, marker: bullet, tight: tight)
                }
                spaceAfter(Self.gap)
            case .table(let header, let rows):
                if let pending = markerText(&marker, font: .systemFont(ofSize: Self.size)) {
                    append(pending, NSAttributedString(), style: paragraph(left: left, marker: ""))
                }
                table(header: header, rows: rows, left: left)
            case .rule:
                let style = paragraph(left: left, marker: nil)
                style.paragraphSpacing = Self.gap
                let text = NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 8)])
                append(nil, text, style: style, extra: [.markdownRule: true])
            }
        }
    }

    /// Cells padded to their column's width in a monospaced font, so the columns line up without a grid.
    private mutating func table(header: [String], rows: [[String]], left: CGFloat) {
        let plain = ([header] + rows).map { $0.map(Self.plainText) }
        let widths = header.indices.map { column in plain.map { $0[column].count }.max() ?? 0 }
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        func line(_ cells: [String]) -> String {
            zip(cells, widths).map { $0 + String(repeating: " ", count: $1 - $0.count) }.joined(separator: "   ").trimmingCharacters(in: .whitespaces)
        }
        for (index, cells) in plain.enumerated() {
            let style = paragraph(left: left, marker: nil)
            style.lineBreakMode = .byTruncatingTail
            if index == plain.count - 1 { style.paragraphSpacing = Self.gap }
            let color = index == 0 ? colors.foreground : colors.foreground.withAlphaComponent(0.9)
            append(nil, NSAttributedString(string: line(cells), attributes: [.font: index == 0 ? bold : font, .foregroundColor: color]),
                   style: style)
            if index == 0 {
                let rule = widths.map { String(repeating: "─", count: $0) }.joined(separator: "   ")
                append(nil, NSAttributedString(string: rule, attributes: [.font: font, .foregroundColor: colors.line]),
                       style: paragraph(left: left, marker: nil))
            }
        }
    }

    /// A list item's first line starts with its bullet, and a tab takes the text to where its other lines start.
    private func paragraph(left: CGFloat, marker: String?) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = left
        style.firstLineHeadIndent = marker == nil ? left : left - Self.step
        style.tabStops = [NSTextTab(textAlignment: .left, location: left)]
        return style
    }

    private func markerText(_ marker: inout String?, font: NSFont) -> NSAttributedString? {
        guard let text = marker else { return nil }
        marker = nil
        return NSAttributedString(string: text + "\t", attributes: [.font: font, .foregroundColor: colors.muted])
    }

    private mutating func append(_ marker: NSAttributedString?, _ text: NSAttributedString, style: NSParagraphStyle,
                                 extra: [NSAttributedString.Key: Any] = [:]) {
        let start = output.length
        if let marker { output.append(marker) }
        output.append(text)
        output.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: Self.size)]))
        let range = NSRange(location: start, length: output.length - start)
        output.addAttribute(.paragraphStyle, value: style, range: range)
        if quote > 0 { output.addAttribute(.markdownQuote, value: quote, range: range) }
        for (key, value) in extra { output.addAttribute(key, value: value, range: range) }
    }

    /// Room after a list or a quote, which ends on its last item's own spacing.
    private func spaceAfter(_ spacing: CGFloat) {
        guard output.length > 0 else { return }
        let last = output.length - 1
        guard let style = (output.attribute(.paragraphStyle, at: last, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy()
                as? NSMutableParagraphStyle else { return }
        style.paragraphSpacing = max(style.paragraphSpacing, spacing)
        let paragraph = (output.string as NSString).paragraphRange(for: NSRange(location: last, length: 0))
        output.addAttribute(.paragraphStyle, value: style, range: paragraph)
    }

    // MARK: Inline

    private static let inlineOptions = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)

    /// Bold, italic, strikethrough, code and links, read by Foundation.
    private func inline(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: text, options: Self.inlineOptions)) ?? AttributedString(text)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            var runFont = font
            if intent.contains(.code) {
                runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                attributes[.foregroundColor] = colors.code
                attributes[.backgroundColor] = colors.codeBackground
            }
            if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            attributes[.font] = runFont
            if let url = run.link.flatMap(resolve) {
                attributes[.link] = url
                attributes[.foregroundColor] = colors.link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            // An image shows as its description, since the pane is text.
            if run.imageURL != nil { attributes[.foregroundColor] = colors.muted }
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }

    /// A relative link, like docs/setup.md, points next to the file. A link to a heading on the page goes nowhere yet.
    private func resolve(_ url: URL) -> URL? {
        if url.scheme != nil { return url }
        guard !url.relativeString.hasPrefix("#"), !folder.isEmpty else { return nil }
        let path = url.relativeString.split(separator: "#").first.map(String.init) ?? url.relativeString
        let decoded = path.removingPercentEncoding ?? path
        return URL(fileURLWithPath: (folder as NSString).appendingPathComponent(decoded)).standardizedFileURL
    }

    /// A cell's text without its Markdown, to measure and pad.
    private static func plainText(_ cell: String) -> String {
        let parsed = (try? AttributedString(markdown: cell, options: inlineOptions)) ?? AttributedString(cell)
        return String(parsed.characters)
    }
}

/// Draws what the text can't: code blocks' backgrounds, quotes' bars and rules, across the width.
final class MarkdownTextView: NSTextView {
    var markdownColors: MarkdownColors? {
        didSet { needsDisplay = true }
    }
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let colors = markdownColors, let layout = layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let visible = layout.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let characters = layout.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        let left = origin.x
        let right = bounds.width - textContainerInset.width

        storage.enumerateAttribute(.markdownCode, in: characters) { value, range, _ in
            guard value != nil else { return }
            let box = bounds(of: range, layout: layout, container: container).insetBy(dx: 0, dy: -6)
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let start = left + (style?.headIndent ?? 12) - 12
            colors.codeBackground.setFill()
            NSBezierPath(roundedRect: NSRect(x: start, y: box.minY, width: right - start, height: box.height), xRadius: 6, yRadius: 6).fill()
        }
        storage.enumerateAttribute(.markdownRule, in: characters) { value, range, _ in
            guard value != nil else { return }
            let box = bounds(of: range, layout: layout, container: container)
            colors.line.setFill()
            NSRect(x: left, y: box.midY.rounded(), width: right - left, height: 1).fill()
        }
        storage.enumerateAttribute(.markdownQuote, in: characters) { value, range, _ in
            guard let depth = value as? Int else { return }
            let box = bounds(of: range, layout: layout, container: container)
            colors.line.setFill()
            for level in 0..<depth {
                NSRect(x: left + CGFloat(level) * 16 + 2, y: box.minY, width: 3, height: box.height).fill()
            }
        }
    }

    /// The lines a range covers, in the view's coordinates, without the spacing after them.
    private func bounds(of range: NSRange, layout: NSLayoutManager, container: NSTextContainer) -> NSRect {
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var box = NSRect.null
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in box = box.union(used) }
        guard !box.isNull else { return .zero }
        return box.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }
}
