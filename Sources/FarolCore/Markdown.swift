import Foundation

/// The blocks of a Markdown file, for the file pane's preview: headings, paragraphs, code, quotes, lists, tables and rules.
/// Inline styles, like bold, code and links, stay in each block's text, for Foundation's own inline parser.
/// ponytail: the common CommonMark and GitHub forms only. No indented code, HTML or reference links, which agents rarely write.
public enum Markdown {
    public indirect enum Block: Equatable {
        case heading(level: Int, text: String)
        /// Lines joined by spaces. A hard break, two trailing spaces or a backslash, stays a newline.
        case paragraph(String)
        case code(language: String?, text: String)
        case quote([Block])
        case list(ordered: Bool, start: Int, items: [Item])
        /// Every row has as many cells as the header.
        case table(header: [String], rows: [[String]])
        case rule
    }

    public struct Item: Equatable {
        /// Nil for a plain item, true or false for a task list's box.
        public var checked: Bool?
        public var blocks: [Block]
    }

    public static func blocks(in text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // Tabs count as four columns, which is how far they indent a list item's content.
        return parse(lines.map { $0.replacingOccurrences(of: "\t", with: "    ") })
    }

    /// Whether the preview offers itself for this file.
    public static func handles(_ path: String) -> Bool {
        ["md", "markdown", "mdx"].contains((path as NSString).pathExtension.lowercased())
    }

    // MARK: Blocks

    static func parse(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(join(paragraph))) }
            paragraph = []
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = indentation(line)
            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }
            // "Title" over a line of = or - makes a heading of the paragraph above.
            if !paragraph.isEmpty, indent < 4, let level = setextLevel(trimmed) {
                blocks.append(.heading(level: level, text: join(paragraph)))
                paragraph = []
                i += 1
                continue
            }
            if indent < 4, let fence = fence(trimmed) {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let closing = lines[i].trimmingCharacters(in: .whitespaces)
                    if indentation(lines[i]) < 4, closing.allSatisfy({ $0 == fence.mark }), closing.count >= fence.length { break }
                    code.append(String(lines[i].dropFirst(min(indent, indentation(lines[i])))))
                    i += 1
                }
                // An unclosed fence runs to the end of the file, as on GitHub.
                i += 1
                blocks.append(.code(language: fence.language, text: code.joined(separator: "\n")))
                continue
            }
            if indent < 4, let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
                i += 1
                continue
            }
            if indent < 4, isRule(trimmed) {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }
            if indent < 4, trimmed.hasPrefix(">") {
                flush()
                var inner: [String] = []
                while i < lines.count {
                    let quoted = lines[i].trimmingCharacters(in: .whitespaces)
                    if quoted.hasPrefix(">") {
                        var rest = quoted.dropFirst()
                        if rest.first == " " { rest = rest.dropFirst() }
                        inner.append(String(rest))
                    } else if !quoted.isEmpty, inner.last?.isEmpty == false, !startsBlock(lines[i]) {
                        // A lazy line carries on the quoted paragraph without its ">".
                        inner.append(quoted)
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.quote(parse(inner)))
                continue
            }
            if indent < 4, i + 1 < lines.count, trimmed.contains("|"), let columns = delimiterRow(lines[i + 1]) {
                flush()
                let header = cells(trimmed, count: columns)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(cells(row, count: columns))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if let first = marker(line) {
                flush()
                var items: [Item] = []
                while i < lines.count, let item = marker(lines[i]), item.ordered == first.ordered, item.indent < first.content {
                    var content = [String(lines[i].dropFirst(min(item.content, lines[i].count)))]
                    i += 1
                    while i < lines.count {
                        let next = lines[i]
                        if next.trimmingCharacters(in: .whitespaces).isEmpty {
                            content.append("")
                        } else if indentation(next) >= item.content {
                            content.append(String(next.dropFirst(item.content)))
                        } else if content.last?.isEmpty == false, !startsBlock(next) {
                            content.append(next.trimmingCharacters(in: .whitespaces))
                        } else {
                            break
                        }
                        i += 1
                    }
                    // Blank lines after an item part it from the next one. A list item doesn't end on them.
                    while content.last?.isEmpty == true { content.removeLast() }
                    var checked: Bool?
                    if let box = content.first?.prefix(4), ["[ ] ", "[x] ", "[X] "].contains(box) {
                        checked = box != "[ ] "
                        content[0] = String(content[0].dropFirst(4))
                    }
                    items.append(Item(checked: checked, blocks: parse(content)))
                }
                blocks.append(.list(ordered: first.ordered, start: first.number, items: items))
                continue
            }
            paragraph.append(line.hasSuffix("  ") ? trimmed + "\\" : trimmed)
            i += 1
        }
        flush()
        return blocks
    }

    /// Lines of a paragraph read as one, except after a hard break.
    private static func join(_ lines: [String]) -> String {
        var text = ""
        for (index, line) in lines.enumerated() {
            let last = index == lines.count - 1
            if line.hasSuffix("\\"), !last {
                text += line.dropLast() + "\n"
            } else {
                text += last && line.hasSuffix("\\") ? String(line.dropLast()) : line + (last ? "" : " ")
            }
        }
        return text
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    /// Whether a line would start a block of its own, so it can't carry on a paragraph.
    private static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard indentation(line) < 4 else { return false }
        return fence(trimmed) != nil || heading(trimmed) != nil || isRule(trimmed) || trimmed.hasPrefix(">") || marker(line) != nil
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #, as in "## Title ##", isn't part of the title.
        if let range = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) { text = String(text[..<range.lowerBound]) }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func setextLevel(_ line: String) -> Int? {
        if line.allSatisfy({ $0 == "=" }) { return 1 }
        if line.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard let mark = marks.first, "-*_".contains(mark), marks.count >= 3 else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    private static func fence(_ line: String) -> (mark: Character, length: Int, language: String?)? {
        guard let mark = line.first, mark == "`" || mark == "~" else { return nil }
        let length = line.prefix { $0 == mark }.count
        guard length >= 3 else { return nil }
        let info = line.dropFirst(length).trimmingCharacters(in: .whitespaces)
        // A backtick fence can't have backticks in its info, or it would be inline code.
        guard mark == "~" || !info.contains("`") else { return nil }
        let language = info.split(separator: " ").first.map(String.init)
        return (mark, length, language)
    }

    /// A list item's start: "- ", "* ", "+ ", "1. " or "1) ". `content` is the column its text starts at.
    private static func marker(_ line: String) -> (ordered: Bool, number: Int, indent: Int, content: Int)? {
        let indent = indentation(line)
        guard indent < 4 else { return nil }
        let rest = line.dropFirst(indent)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let ordered = !digits.isEmpty
        let width: Int
        if ordered {
            guard digits.count <= 9, let delimiter = rest.dropFirst(digits.count).first, delimiter == "." || delimiter == ")" else { return nil }
            width = digits.count + 1
        } else {
            guard let bullet = rest.first, "-*+".contains(bullet) else { return nil }
            width = 1
        }
        let after = rest.dropFirst(width)
        // "-" alone is an empty item. "-x" is just text.
        guard after.isEmpty || after.first == " " else { return nil }
        let spaces = after.prefix { $0 == " " }.count
        // Past four spaces, the rest is the item's indented content, so the text starts one space in.
        let gap = after.count == spaces || spaces > 4 ? 1 : spaces
        return (ordered, Int(digits) ?? 1, indent, indent + width + gap)
    }

    /// "| --- | :---: |" under a table's first row. Returns how many columns it has.
    private static func delimiterRow(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.contains(":") else { return nil }
        let parts = cells(trimmed, count: nil)
        let valid = parts.allSatisfy { $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }
        return valid && !parts.isEmpty ? parts.count : nil
    }

    /// Splits a row on its pipes, leaving out the outer ones. `count` pads or cuts it to the header's width.
    private static func cells(_ row: String, count: Int?) -> [String] {
        var text = Substring(row)
        if text.hasPrefix("|") { text = text.dropFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text = text.dropLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in text {
            if escaped {
                cell += character == "|" ? "|" : "\\\(character)"
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        guard let count else { return cells }
        return Array((cells + Array(repeating: "", count: max(0, count - cells.count))).prefix(count))
    }
}
