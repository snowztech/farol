import Foundation

/// A Vue single file component, colored by its sections. `<script>` is JavaScript or TypeScript and `<style>` is CSS.
/// The template is HTML, with its directives and the expressions in them and in `{{ }}` read as JavaScript.
extension Syntax {
    static func vueTokens(in text: String) -> [Token] {
        let string = text as NSString
        let blocks = sections(in: string)

        // The template is read with the script and style blank, so a quote in them can't run into it.
        var masked = Array(text.utf16)
        for block in blocks.map(\.content) {
            for at in block.location..<NSMaxRange(block) where masked[at] != 10 { masked[at] = 32 }
        }
        let template = String(utf16CodeUnits: masked, count: masked.count)
        var result = Syntax.tokens(in: template, html)
        let comments = result.filter { $0.kind == .comment }.map(\.range)

        // Where an expression is, so the string the HTML pass made of it gives way to the JavaScript inside.
        var expressions: [NSRange] = []
        var extra: [Token] = []
        // Tag names as written, with their hyphens, which the HTML pass cuts short: <my-button> is one tag name.
        var names: Set<Int> = []
        func inComment(_ at: Int) -> NSRange? { comments.first { NSLocationInRange(at, $0) } }

        let chars = masked
        var i = 0
        while i < chars.count {
            if let comment = inComment(i) {
                i = NSMaxRange(comment)
            } else if chars[i] == 60, let name = tagName(chars, after: i) {
                extra.append(Token(range: name, kind: .tag))
                names.insert(name.location)
                i = NSMaxRange(name)
                if chars[name.location - 1] == 60 { i = scanTag(chars, from: i, expressions: &expressions, extra: &extra) }
            } else if chars[i] == 123, i + 1 < chars.count, chars[i + 1] == 123 {
                // {{ expression }}
                var end = i + 2
                while end + 1 < chars.count, !(chars[end] == 125 && chars[end + 1] == 125) { end += 1 }
                guard end + 1 < chars.count else { break }
                expressions.append(NSRange(location: i + 2, length: end - i - 2))
                i = end + 2
            } else {
                i += 1
            }
        }

        result.removeAll { token in
            (token.kind == .tag && names.contains(token.range.location))
                || expressions.contains { NSIntersectionRange($0, token.range).length > 0 }
        }
        for range in expressions {
            result += Syntax.tokens(in: string.substring(with: range), javascript).map { shifted($0, by: range.location) }
        }
        result += extra
        for block in blocks {
            let inner = string.substring(with: block.content)
            result += Syntax.tokens(in: inner, block.isStyle ? css : javascript).map { shifted($0, by: block.content.location) }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    private struct Section {
        let content: NSRange
        let isStyle: Bool
    }

    /// The text between `<script ...>` and `</script>`, and `<style ...>` and `</style>`.
    private static func sections(in string: NSString) -> [Section] {
        guard let open = try? NSRegularExpression(pattern: #"<(script|style)\b[^>]*>"#, options: .caseInsensitive) else { return [] }
        var sections: [Section] = []
        var from = 0
        while from < string.length,
              let match = open.firstMatch(in: string as String, range: NSRange(location: from, length: string.length - from)) {
            let name = string.substring(with: match.range(at: 1)).lowercased()
            let start = NSMaxRange(match.range)
            let close = string.range(of: "</\(name)>", options: .caseInsensitive,
                                     range: NSRange(location: start, length: string.length - start))
            let end = close.location == NSNotFound ? string.length : close.location
            sections.append(Section(content: NSRange(location: start, length: end - start), isStyle: name == "style"))
            from = close.location == NSNotFound ? string.length : NSMaxRange(close)
        }
        return sections
    }

    /// The name after a `<` or `</`, hyphens included, or nil when the `<` is not a tag, as in `a < b` or `<!--`.
    private static func tagName(_ chars: [UInt16], after open: Int) -> NSRange? {
        var start = open + 1
        if start < chars.count, chars[start] == 47 { start += 1 }
        guard start < chars.count, isLetter(chars[start]) else { return nil }
        var end = start
        while end < chars.count, isWord(chars[end]) || chars[end] == 45 { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The attributes of a tag, from the end of its name. Directive names are keywords, and what a directive's quotes hold is an expression.
    /// Returns where the tag ends. A quote may hold a `>`, as in `v-if="a > b"`, so the end is the first one outside quotes.
    private static func scanTag(_ chars: [UInt16], from nameEnd: Int, expressions: inout [NSRange], extra: inout [Token]) -> Int {
        var i = nameEnd
        while i < chars.count, chars[i] != 62 {
            guard !isSpace(chars[i]), chars[i] != 47 else {
                i += 1
                continue
            }
            // An attribute: its name, then `=` and a quoted value, or nothing.
            let nameStart = i
            while i < chars.count, !isSpace(chars[i]), chars[i] != 61, chars[i] != 62, chars[i] != 47 { i += 1 }
            let directive = isDirective(chars[nameStart..<i])
            if directive { extra.append(Token(range: NSRange(location: nameStart, length: i - nameStart), kind: .keyword)) }
            guard i < chars.count, chars[i] == 61 else { continue }
            i += 1
            guard i < chars.count, chars[i] == 34 || chars[i] == 39 else { continue }
            let quote = chars[i]
            let valueStart = i + 1
            var end = valueStart
            while end < chars.count, chars[end] != quote { end += 1 }
            let value = NSRange(location: valueStart, length: end - valueStart)
            if directive {
                expressions.append(value)
            } else if quote == 39 {
                // The HTML pass only knows double quotes.
                extra.append(Token(range: NSRange(location: valueStart - 1, length: min(end + 1, chars.count) - valueStart + 1), kind: .string))
            }
            i = min(end + 1, chars.count)
        }
        return min(i + 1, chars.count)
    }

    /// `v-if`, `:class`, `@click` and `#default`.
    private static func isDirective(_ name: ArraySlice<UInt16>) -> Bool {
        guard let first = name.first else { return false }
        if first == 58 || first == 64 || first == 35 { return name.count > 1 }
        return name.starts(with: Array("v-".utf16)) && name.count > 2
    }

    private static func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }

    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

    private static func shifted(_ token: Token, by offset: Int) -> Token {
        Token(range: NSRange(location: token.range.location + offset, length: token.range.length), kind: token.kind)
    }
}
