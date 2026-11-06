import Foundation

/// HTML, and the component files of Vue, Svelte and Astro, in one pass.
/// Tags and attributes are read here, and the code inside goes to its own lexer: `<script>` as JavaScript or TypeScript, `<style>` as CSS, and a framework's expressions as JavaScript.
/// Text between tags is prose, so it stays plain.
extension Syntax {
    /// What a framework adds to HTML. Plain HTML adds nothing.
    public struct Markup {
        /// What wraps an expression in text, like Vue's `{{ }}` or Svelte's `{ }`. With `{`, an attribute's value can be one too.
        var expression: (open: String, close: String)?
        /// Attribute names that belong to the framework, like Vue's `v-if` and `:prop`, colored as keywords.
        var directives: [String] = []
        /// A directive's quoted value is code, as in Vue's `:class="{ on: isOn }"`.
        var quotedCode = false
        /// Astro's `---` block at the top, which is TypeScript.
        var frontmatter = false
    }

    static func markupTokens(in text: String, _ markup: Markup) -> [Token] {
        let chars = Array(text.utf16)
        // Tag names are found whatever their case, like `</SCRIPT>`.
        let lower = chars.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
        let count = chars.count
        let (lt, gt, slash, equals, open, close) = (code("<"), code(">"), code("/"), code("="), code("{"), code("}"))
        let braces = markup.expression?.open == "{"
        let opener = markup.expression.map { Array($0.open.utf16) }, closer = markup.expression.map { Array($0.close.utf16) }
        let commentOpen = Array("<!--".utf16)
        var tokens: [Token] = []

        func add(_ start: Int, _ end: Int, _ kind: Kind) {
            tokens.append(Token(range: NSRange(location: start, length: end - start), kind: kind))
        }
        func lex(_ start: Int, _ end: Int, _ language: Language) {
            guard end > start else { return }
            let inner = String(utf16CodeUnits: Array(chars[start..<end]), count: end - start)
            tokens += Syntax.tokens(in: inner, language).map {
                Token(range: NSRange(location: $0.range.location + start, length: $0.range.length), kind: $0.kind)
            }
        }
        func starts(_ needle: [UInt16], at i: Int) -> Bool {
            i + needle.count <= count && lower[i..<i + needle.count].elementsEqual(needle)
        }
        func find(_ needle: [UInt16], from start: Int) -> Int? {
            var i = start
            while i < count, !starts(needle, at: i) { i += 1 }
            return i < count ? i : nil
        }
        /// The `}` that closes the `{` at `start`, past the braces and strings inside, like `{ { a: '}' } }`.
        func closingBrace(_ start: Int) -> Int? {
            var depth = 0
            var i = start
            while i < count {
                let c = chars[i]
                if c == code("\"") || c == code("'") || c == code("`") {
                    i += 1
                    while i < count, chars[i] != c { i += chars[i] == code("\\") ? 2 : 1 }
                } else if c == open {
                    depth += 1
                } else if c == close {
                    depth -= 1
                    if depth == 0 { return i }
                }
                i += 1
            }
            return nil
        }
        /// The expression starting at `start`, as the range of its code and where reading goes on, or nil when it isn't closed.
        func expression(at start: Int) -> (code: Range<Int>, next: Int)? {
            guard let opener, let closer, starts(opener, at: start) else { return nil }
            let end = braces ? closingBrace(start) : find(closer, from: start + opener.count)
            guard let end else { return nil }
            return (start + opener.count..<end, end + closer.count)
        }

        /// Reads a tag's attributes from after its name, and returns where the tag ends and whether it closed itself.
        func attributes(from start: Int) -> (end: Int, selfClosing: Bool) {
            var i = start
            while i < count, chars[i] != gt {
                if isSpace(chars[i]) || chars[i] == slash {
                    i += 1
                    continue
                }
                // Svelte's `{name}` shorthand and `{...props}`.
                if braces, chars[i] == open, let found = expression(at: i) {
                    lex(found.code.lowerBound, found.code.upperBound, javascript)
                    i = found.next
                    continue
                }
                let name = i
                while i < count, !isSpace(chars[i]), chars[i] != equals, chars[i] != gt, chars[i] != slash { i += 1 }
                let attribute = String(utf16CodeUnits: Array(chars[name..<i]), count: i - name)
                let directive = markup.directives.contains { attribute.hasPrefix($0) && attribute.count > $0.count }
                if directive { add(name, i, .keyword) }
                var value = i
                while value < count, isSpace(chars[value]) { value += 1 }
                guard value < count, chars[value] == equals else { continue }
                value += 1
                while value < count, isSpace(chars[value]) { value += 1 }
                i = value
                guard i < count else { break }
                let quote = chars[i]
                if quote == code("\"") || quote == code("'") {
                    // A value can span lines. One left open while typing stops at its line.
                    var end = i + 1
                    while end < count, chars[end] != quote { end += 1 }
                    if end == count {
                        end = i + 1
                        while end < count, chars[end] != code("\n") { end += 1 }
                    }
                    let past = min(end + 1, count)
                    if directive, markup.quotedCode { lex(i + 1, end, javascript) } else { add(i, past, .string) }
                    i = past
                } else if braces, quote == open, let found = expression(at: i) {
                    lex(found.code.lowerBound, found.code.upperBound, javascript)
                    i = found.next
                } else {
                    while i < count, !isSpace(chars[i]), chars[i] != gt { i += 1 }
                }
            }
            return (min(i + 1, count), i > start && chars[i - 1] == slash)
        }

        var i = 0
        if markup.frontmatter, starts(Array("---".utf16), at: 0), let end = find(Array("\n---".utf16), from: 3) {
            lex(3, end, javascript)
            i = end + 4
        }
        while i < count {
            if starts(commentOpen, at: i) {
                let end = find(Array("-->".utf16), from: i + 4).map { $0 + 3 } ?? count
                add(i, end, .comment)
                i = end
            } else if chars[i] == lt, i + 1 < count, chars[i + 1] == code("!") {
                // `<!DOCTYPE html>`.
                var end = i + 2
                while end < count, isLetter(chars[end]) { end += 1 }
                if end > i + 2 { add(i + 2, end, .keyword) }
                i = end
            } else if chars[i] == lt, let name = tagName(chars, after: i) {
                add(name.lowerBound, name.upperBound, .tag)
                let closing = chars[i + 1] == slash
                let tag = String(utf16CodeUnits: Array(lower[name]), count: name.count)
                let (end, selfClosing) = closing ? (name.upperBound, true) : attributes(from: name.upperBound)
                i = end
                if !selfClosing, tag == "script" || tag == "style" {
                    let body = find(Array(("</" + tag).utf16), from: i) ?? count
                    lex(i, body, tag == "style" ? css : javascript)
                    i = body
                }
            } else if let found = expression(at: i) {
                lex(found.code.lowerBound, found.code.upperBound, javascript)
                i = found.next
            } else {
                i += 1
            }
        }
        return tokens
    }

    /// The name of the tag opened at `start`, with the hyphens, dots and colons of `<my-button>`, `<Foo.Bar>` and `<svelte:head>`.
    /// Nil for a `<` that opens no tag, like the one in `1 < 2`.
    private static func tagName(_ chars: [UInt16], after start: Int) -> Range<Int>? {
        var name = start + 1
        if name < chars.count, chars[name] == code("/") || chars[name] == code("?") { name += 1 }
        guard name < chars.count, isLetter(chars[name]) else { return nil }
        var end = name
        while end < chars.count, isWord(chars[end]) || chars[end] == code("-") || chars[end] == code(".") || chars[end] == code(":") { end += 1 }
        return name..<end
    }

    private static func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }

    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
}
