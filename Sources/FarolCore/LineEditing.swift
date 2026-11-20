import Foundation

/// The editor's line commands, as plain text in and one edit out, so each is a single undo.
/// Every command works on the lines the selection touches, or the cursor's line.
public enum LineEditing {
    public enum Comment: Equatable {
        case line(String)
        case block(String, String)
    }

    public struct Edit: Equatable {
        public let range: NSRange
        public let replacement: String
        /// Where the selection goes after the edit, in the new text.
        public let selection: NSRange
    }

    /// The lines the selection touches, with their line breaks. A selection ending at a line's start leaves that line out.
    public static func lines(_ text: NSString, _ selection: NSRange) -> NSRange {
        var range = selection
        if range.length > 0, text.character(at: NSMaxRange(range) - 1) == 0x0A { range.length -= 1 }
        return text.lineRange(for: range)
    }

    /// Swaps the lines with the one above or below, the selection moving with them.
    public static func move(_ text: NSString, _ selection: NSRange, up: Bool) -> Edit? {
        let block = lines(text, selection)
        if up {
            guard block.location > 0 else { return nil }
            let above = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
            let swapped = swap(text, first: above, second: block)
            return Edit(range: NSUnionRange(above, block), replacement: swapped.text,
                        selection: NSRange(location: selection.location - above.length, length: selection.length))
        }
        guard NSMaxRange(block) < text.length else { return nil }
        let below = text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
        let swapped = swap(text, first: block, second: below)
        let range = NSUnionRange(block, below)
        // A selection that took the last line's break with it loses that break, which now sits between the swapped lines.
        let start = selection.location + swapped.topLength
        let end = min(NSMaxRange(selection) + swapped.topLength, range.location + (swapped.text as NSString).length)
        return Edit(range: range, replacement: swapped.text, selection: NSRange(location: start, length: end - start))
    }

    /// `second` then `first`, with a line break between them even when `second` was the last line and had none.
    private static func swap(_ text: NSString, first: NSRange, second: NSRange) -> (text: String, topLength: Int) {
        var top = text.substring(with: second)
        var bottom = text.substring(with: first)
        if !top.hasSuffix("\n") {
            top += "\n"
            bottom.removeLast()
        }
        return (top + bottom, (top as NSString).length)
    }

    /// A copy of the lines below them, the selection going with the copy, or above them, the selection staying.
    public static func duplicate(_ text: NSString, _ selection: NSRange, up: Bool) -> Edit {
        let block = lines(text, selection)
        let copy = text.substring(with: block)
        if !copy.hasSuffix("\n") {
            // The last line: the break goes between the two copies.
            return Edit(range: NSRange(location: NSMaxRange(block), length: 0), replacement: "\n" + copy,
                        selection: up ? selection : NSRange(location: selection.location + block.length + 1, length: selection.length))
        }
        return Edit(range: NSRange(location: block.location, length: 0), replacement: copy,
                    selection: up ? selection : NSRange(location: selection.location + block.length, length: selection.length))
    }

    /// Removes the lines, the cursor landing where they began.
    public static func delete(_ text: NSString, _ selection: NSRange) -> Edit {
        var block = lines(text, selection)
        // The last line has no break of its own, so the one before it goes too.
        if NSMaxRange(block) == text.length, block.location > 0, text.character(at: NSMaxRange(block) - 1) != 0x0A {
            block = NSRange(location: block.location - 1, length: block.length + 1)
        }
        let cursor = min(block.location, max(0, text.length - block.length))
        return Edit(range: block, replacement: "", selection: NSRange(location: cursor, length: 0))
    }

    /// Comments the lines out at their shared indent, or back in when every line with text already is. Blank lines are left alone.
    public static func toggleComment(_ text: NSString, _ selection: NSRange, _ comment: Comment) -> Edit {
        let block = lines(text, selection)
        let source = text.substring(with: block)
        let ending = source.hasSuffix("\n") ? "\n" : ""
        let rows = String(source.dropLast(ending.count)).components(separatedBy: "\n")
        let (open, close): (String, String) = switch comment {
        case .line(let marker): (marker, "")
        case .block(let start, let end): (start, end)
        }
        let filled = rows.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let indent = filled.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        let commented = !filled.isEmpty && filled.allSatisfy {
            let body = $0.trimmingCharacters(in: .whitespaces)
            return body.hasPrefix(open) && body.hasSuffix(close)
        }
        // How far the cursor's line moved before the cursor, for a cursor to keep its place in the text.
        var shift = 0
        let column = selection.location - block.location
        let changed = rows.map { row -> String in
            guard !row.trimmingCharacters(in: .whitespaces).isEmpty else { return row }
            if commented {
                let lead = row.prefix { $0 == " " || $0 == "\t" }
                var body = String(row.dropFirst(lead.count).dropFirst(open.count))
                var removed = (open as NSString).length
                if body.hasPrefix(" ") {
                    body.removeFirst()
                    removed += 1
                }
                shift = -min(removed, max(0, column - (String(lead) as NSString).length))
                if !close.isEmpty {
                    body = String(body.trimmingCharacters(in: .whitespaces).dropLast(close.count))
                    while body.hasSuffix(" ") { body.removeLast() }
                }
                return lead + body
            }
            let lead = row.prefix(indent)
            if column >= (String(lead) as NSString).length { shift = (open as NSString).length + 1 }
            return lead + open + " " + row.dropFirst(indent) + (close.isEmpty ? "" : " " + close)
        }
        let replacement = changed.joined(separator: "\n") + ending
        let length = (replacement as NSString).length - (ending as NSString).length
        // A selection becomes the whole lines, so ⌘/ again takes it back. A cursor keeps its place in the text.
        let after = selection.length > 0
            ? NSRange(location: block.location, length: length)
            : NSRange(location: min(max(block.location, selection.location + shift), block.location + length), length: 0)
        return Edit(range: block, replacement: replacement, selection: after)
    }
}
