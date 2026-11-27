import Foundation

/// What a code editor does as you type: indents, pairs and new lines, as plain text in and one edit out, so each is a single undo.
public enum Typing {
    public typealias Edit = LineEditing.Edit

    static let pairs: [String: String] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
    static let closers: Set<String> = [")", "]", "}"]

    // MARK: Indent

    /// The file's indent: a tab, or the step most of its indented lines take, from 2 to 8 spaces. `fallback` when it can't tell.
    /// Steps of one space are left out, since they are mostly the stars of block comments.
    public static func indentUnit(of text: NSString, fallback: String = "    ") -> String {
        let sample = text.length > 200_000 ? text.substring(to: 200_000) : text as String
        var tabs = 0, steps: [Int: Int] = [:], previous = 0
        for line in sample.split(separator: "\n").prefix(5000) {
            if line.hasPrefix("\t") {
                tabs += 1
                continue
            }
            let spaces = line.prefix { $0 == " " }.count
            guard spaces < line.count else { continue }
            let step = abs(spaces - previous)
            if (2...8).contains(step) { steps[step, default: 0] += 1 }
            previous = spaces
        }
        let spaced = steps.values.reduce(0, +)
        if tabs > spaced { return "\t" }
        guard let step = steps.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key else { return fallback }
        return String(repeating: " ", count: step)
    }

    /// Tab: with a selection across lines, every line moves in a level. Otherwise an indent goes in at the cursor, spaces up to the next stop.
    public static func indent(_ text: NSString, _ selection: NSRange, unit: String) -> Edit {
        guard spansLines(text, selection) else {
            let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
            let column = selection.location - line.location
            let insert = unit == "\t" ? "\t" : String(repeating: " ", count: unit.count - column % unit.count)
            return Edit(range: selection, replacement: insert, selection: NSRange(location: selection.location + (insert as NSString).length, length: 0))
        }
        return eachLine(text, selection) { line in line.isEmpty ? line : unit + line }
    }

    /// ⇧Tab: the lines move out a level, as far as they can. Nil when none can.
    public static func outdent(_ text: NSString, _ selection: NSRange, unit: String) -> Edit? {
        let width = unit == "\t" ? 4 : unit.count
        let edit = eachLine(text, selection) { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return String(line.dropFirst(min(width, line.prefix { $0 == " " }.count)))
        }
        guard edit.replacement != text.substring(with: edit.range) else { return nil }
        guard selection.length == 0 else { return edit }
        // A cursor stays on its character, or at the start of the text once its indent is gone.
        let removed = (text.substring(with: edit.range) as NSString).length - (edit.replacement as NSString).length
        return Edit(range: edit.range, replacement: edit.replacement,
                    selection: NSRange(location: max(edit.range.location, selection.location - removed), length: 0))
    }

    /// Changes the lines the selection touches, then selects them whole, so the same key again goes on from there.
    private static func eachLine(_ text: NSString, _ selection: NSRange, _ change: (String) -> String) -> Edit {
        let block = LineEditing.lines(text, selection)
        let source = text.substring(with: block)
        let ending = source.hasSuffix("\n") ? "\n" : ""
        let replacement = String(source.dropLast(ending.count)).components(separatedBy: "\n").map(change).joined(separator: "\n") + ending
        let length = (replacement as NSString).length - (ending as NSString).length
        return Edit(range: block, replacement: replacement, selection: NSRange(location: block.location, length: length))
    }

    private static func spansLines(_ text: NSString, _ selection: NSRange) -> Bool {
        selection.length > 0 && text.rangeOfCharacter(from: .newlines, options: [], range: selection).location != NSNotFound
    }

    // MARK: Pairs

    /// A typed bracket or quote. An opener with text selected wraps it. One with nothing after it gets its closer too, the cursor between.
    /// A closer typed where the same closer already is steps over it. Nil types the character as it is.
    public static func type(_ character: String, _ text: NSString, _ selection: NSRange) -> Edit? {
        let next = selection.length == 0 ? char(text, selection.location) : nil
        let previous = char(text, selection.location - 1)
        let isQuote = character == "\"" || character == "'" || character == "`"
        if selection.length == 0, next == character, closers.contains(character) || isQuote {
            return Edit(range: selection, replacement: "", selection: NSRange(location: selection.location + 1, length: 0))
        }
        guard let close = pairs[character] else { return nil }
        if selection.length > 0 {
            let inner = text.substring(with: selection)
            return Edit(range: selection, replacement: character + inner + close,
                        selection: NSRange(location: selection.location + 1, length: selection.length))
        }
        // Only where nothing follows that the pair would wrap, so typing before a word doesn't leave a stray closer.
        guard next == nil || next!.first!.isWhitespace || closers.contains(next!) || next == "," || next == ";" else { return nil }
        // A quote after a letter is an apostrophe, like in don't, or a string's prefix, like f".
        if isQuote, let previous, previous.first!.isLetter || previous.first!.isNumber || previous == character { return nil }
        return Edit(range: selection, replacement: character + close, selection: NSRange(location: selection.location + 1, length: 0))
    }

    /// Backspace between an empty pair takes both. In the spaces that start a line it takes back to the previous stop.
    /// Nil leaves it to the text view, which takes one character.
    public static func deleteBackward(_ text: NSString, _ selection: NSRange, unit: String) -> Edit? {
        guard selection.length == 0, selection.location > 0 else { return nil }
        let at = selection.location
        if let open = char(text, at - 1), let close = pairs[open], char(text, at) == close {
            return Edit(range: NSRange(location: at - 1, length: 2), replacement: "", selection: NSRange(location: at - 1, length: 0))
        }
        guard unit != "\t" else { return nil }
        let line = text.lineRange(for: NSRange(location: at, length: 0))
        let column = at - line.location
        guard column > 1, text.substring(with: NSRange(location: line.location, length: column)).allSatisfy({ $0 == " " }) else { return nil }
        let back = column % unit.count == 0 ? unit.count : column % unit.count
        guard back > 1 else { return nil }
        return Edit(range: NSRange(location: at - back, length: back), replacement: "", selection: NSRange(location: at - back, length: 0))
    }

    // MARK: New lines

    /// Return keeps the line's indent and adds a level after an opening bracket or a colon.
    /// Between a pair like `{}` the cursor gets a line of its own.
    /// `colonOpens` is for languages where a colon starts a block, like Python and YAML. In prose it would only push the next line in.
    public static func newline(_ text: NSString, _ selection: NSRange, unit: String, colonOpens: Bool = true) -> Edit {
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        let last = before.trimmingCharacters(in: .whitespaces).last.map(String.init)
        let restOfLine = text.substring(with: NSRange(location: NSMaxRange(selection), length: max(0, lineEnd(text, line) - NSMaxRange(selection))))
        let opens = last.map { pairs[$0] != nil && closers.contains(pairs[$0]!) } ?? false
        let colon = colonOpens && last == ":" && restOfLine.trimmingCharacters(in: .whitespaces).isEmpty
        guard opens || colon else {
            let replacement = "\n" + indent
            return Edit(range: selection, replacement: replacement, selection: NSRange(location: selection.location + (replacement as NSString).length, length: 0))
        }
        let inner = "\n" + indent + unit
        let closes = opens && char(text, NSMaxRange(selection)) == pairs[last!]
        let replacement = inner + (closes ? "\n" + indent : "")
        return Edit(range: selection, replacement: replacement, selection: NSRange(location: selection.location + (inner as NSString).length, length: 0))
    }

    // MARK: Brackets

    /// The bracket beside the cursor, just before it first, and the one that matches it. Nil when there's none, or no match within reach.
    /// Brackets inside strings aren't told apart, which only misleads where a string holds an odd bracket.
    public static func matchingBracket(_ text: NSString, at location: Int, reach: Int = 20_000) -> (NSRange, NSRange)? {
        for at in [location - 1, location] {
            guard let bracket = char(text, at) else { continue }
            if let close = pairs[bracket], closers.contains(close) {
                if let match = scan(text, from: at + 1, step: 1, open: bracket, close: close, reach: reach) {
                    return (NSRange(location: at, length: 1), NSRange(location: match, length: 1))
                }
            } else if closers.contains(bracket), let open = pairs.first(where: { $0.value == bracket })?.key {
                if let match = scan(text, from: at - 1, step: -1, open: bracket, close: open, reach: reach) {
                    return (NSRange(location: at, length: 1), NSRange(location: match, length: 1))
                }
            }
        }
        return nil
    }

    /// Walks from `start` counting nesting until the bracket that closes it, `open` being the one being matched.
    private static func scan(_ text: NSString, from start: Int, step: Int, open: String, close: String, reach: Int) -> Int? {
        let (openUnit, closeUnit) = ((open as NSString).character(at: 0), (close as NSString).character(at: 0))
        var depth = 0, at = start, walked = 0
        while at >= 0, at < text.length, walked < reach {
            let unit = text.character(at: at)
            if unit == openUnit { depth += 1 } else if unit == closeUnit {
                if depth == 0 { return at }
                depth -= 1
            }
            at += step
            walked += 1
        }
        return nil
    }

    private static func char(_ text: NSString, _ location: Int) -> String? {
        guard location >= 0, location < text.length else { return nil }
        return text.substring(with: text.rangeOfComposedCharacterSequence(at: location))
    }

    private static func lineEnd(_ text: NSString, _ line: NSRange) -> Int {
        NSMaxRange(line) - (NSMaxRange(line) > line.location && text.character(at: NSMaxRange(line) - 1) == 0x0A ? 1 : 0)
    }
}
