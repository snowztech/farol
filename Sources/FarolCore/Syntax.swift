import Foundation

/// Just enough highlighting to make code easy to read: comments, strings, numbers and keywords.
/// One pass and no grammar, so it stays fast and needs no dependency.
/// Nested template strings and the like come out wrong. A real parser would fix that if it ever matters.
public enum Syntax {
    public enum Kind: Equatable { case keyword, string, number, comment }

    public struct Token: Equatable {
        /// UTF-16 offsets, ready for NSAttributedString and AttributedString.
        public let range: NSRange
        public let kind: Kind
    }

    public struct Language {
        let lineComments: [String]
        let blockComments: [(open: String, close: String)]
        let quotes: Set<Character>
        /// Quotes whose strings can span lines, like JavaScript's backtick.
        var multilineQuotes: Set<Character> = []
        let keywords: Set<String>
        /// Markup: the name right after `<` or `</` is colored like a keyword.
        var tagNames = false
        /// Markdown is colored by lines instead, see markdownTokens.
        var isMarkdown = false
    }

    /// The language for a file name, or nil when Farol doesn't color it.
    public static func language(for path: String) -> Language? {
        let name = (path as NSString).lastPathComponent
        if ["Makefile", "Dockerfile", "Gemfile", "Rakefile"].contains(name) { return name == "Gemfile" || name == "Rakefile" ? ruby : shell }
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return swift
        case "go": return go
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": return javascript
        case "py": return python
        case "rs": return rust
        case "rb": return ruby
        case "sh", "bash", "zsh", "fish": return shell
        case "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "kts", "cs", "scala", "dart": return cFamily
        case "json", "jsonc": return json
        case "yml", "yaml", "toml", "ini", "conf": return config
        case "css", "scss": return css
        case "html", "htm", "xml", "svg", "plist", "vue", "svelte": return html
        case "md", "markdown", "mdx": return markdown
        default: return nil
        }
    }

    public static func tokens(in text: String, _ language: Language) -> [Token] {
        if language.isMarkdown { return markdownTokens(in: text) }
        let chars = Array(text.utf16)
        var tokens: [Token] = []
        var i = 0
        func starts(with s: String, at index: Int) -> Bool {
            let u = Array(s.utf16)
            return index + u.count <= chars.count && Array(chars[index..<index + u.count]) == u
        }
        func add(_ start: Int, _ end: Int, _ kind: Kind) {
            tokens.append(Token(range: NSRange(location: start, length: end - start), kind: kind))
        }
        let newline = code("\n"), backslash = code("\\")
        let quotes = Set(language.quotes.compactMap { $0.utf16.first })
        let multiline = Set(language.multilineQuotes.compactMap { $0.utf16.first })

        while i < chars.count {
            let c = chars[i]
            if let block = language.blockComments.first(where: { starts(with: $0.open, at: i) }) {
                var end = i + block.open.utf16.count
                while end < chars.count, !starts(with: block.close, at: end) { end += 1 }
                end = min(end + block.close.utf16.count, chars.count)
                add(i, end, .comment)
                i = end
            } else if language.lineComments.contains(where: { starts(with: $0, at: i) }) {
                var end = i
                while end < chars.count, chars[end] != newline { end += 1 }
                add(i, end, .comment)
                i = end
            } else if quotes.contains(c) {
                var end = i + 1
                while end < chars.count, chars[end] != c {
                    if chars[end] == backslash { end += 1 }
                    // An unclosed quote stops at the line's end, so one stray quote can't color the rest of the file.
                    else if chars[end] == newline, !multiline.contains(c) { break }
                    end += 1
                }
                // Include the closing quote, but not the line break of an unclosed one.
                if end < chars.count, chars[end] == c { end += 1 }
                add(i, end, .string)
                i = end
            } else if isDigit(c), i == 0 || !isWord(chars[i - 1]) {
                var end = i
                while end < chars.count, isWord(chars[end]) || chars[end] == code(".") { end += 1 }
                add(i, end, .number)
                i = end
            } else if isWord(c) {
                var end = i
                while end < chars.count, isWord(chars[end]) { end += 1 }
                let word = String(utf16CodeUnits: Array(chars[i..<end]), count: end - i)
                // A dotted name like `.default` or `obj.type` is a member, not the keyword.
                let afterDot = i > 0 && chars[i - 1] == code(".")
                let isTag = language.tagNames && i > 0
                    && (chars[i - 1] == code("<") || (i > 1 && chars[i - 1] == code("/") && chars[i - 2] == code("<")))
                if isTag || (!afterDot && language.keywords.contains(word)) { add(i, end, .keyword) }
                i = end
            } else {
                i += 1
            }
        }
        return tokens
    }

    /// Headings and list markers like keywords, code like strings, quotes and link targets muted like comments.
    private static func markdownTokens(in text: String) -> [Token] {
        let string = text as NSString
        var tokens: [Token] = []
        var inFence = false
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { line, range, _, _ in
            guard let line else { return }
            let trimmed = line.drop { $0 == " " }
            let indent = line.count - trimmed.count
            func add(_ location: Int, _ length: Int, _ kind: Kind) {
                tokens.append(Token(range: NSRange(location: range.location + location, length: length), kind: kind))
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return add(0, range.length, .string)
            }
            if inFence { return add(0, range.length, .string) }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " { return add(0, range.length, .keyword) }
            if trimmed.hasPrefix(">") { return add(0, range.length, .comment) }
            let utf16 = Array(line.utf16)
            var marker = 0
            if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
                marker = 1
            } else {
                let digits = trimmed.prefix { $0.isNumber }.count
                if digits > 0, trimmed.dropFirst(digits).hasPrefix(". ") { marker = digits + 1 }
            }
            if marker > 0 { add(indent, marker, .keyword) }
            // Inline code, then link targets after `](`, found on the line's UTF-16 so offsets match the text.
            var i = 0
            let tick = UInt16(UInt8(ascii: "`"))
            while i < utf16.count {
                if utf16[i] == tick, let end = utf16[(i + 1)...].firstIndex(of: tick) {
                    add(i, end - i + 1, .string)
                    i = end + 1
                } else if utf16[i] == UInt16(UInt8(ascii: "]")), i + 1 < utf16.count, utf16[i + 1] == UInt16(UInt8(ascii: "(")),
                          let end = utf16[(i + 1)...].firstIndex(of: UInt16(UInt8(ascii: ")"))) {
                    add(i + 1, end - i, .comment)
                    i = end + 1
                } else {
                    i += 1
                }
            }
        }
        return tokens
    }

    private static func code(_ c: Unicode.Scalar) -> UInt16 { UInt16(c.value) }

    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }

    private static func isWord(_ c: UInt16) -> Bool {
        isDigit(c) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c == 64
    }

    // MARK: Languages

    private static func words(_ list: String) -> Set<String> { Set(list.split(separator: " ").map(String.init)) }

    static let swift = Language(lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\""], keywords: words(
        "let var func if else guard return for in while repeat switch case default break continue fallthrough struct class enum protocol extension import init deinit self Self nil true false throw throws rethrows try catch do async await private public internal fileprivate open static final override mutating nonmutating where as is some any lazy weak unowned defer typealias inout operator subscript get set willSet didSet associatedtype convenience required indirect"))

    static let go = Language(lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\"", "'", "`"], multilineQuotes: ["`"], keywords: words(
        "package import func var const type struct interface map chan if else for range return go defer select switch case default break continue fallthrough goto nil true false iota"))

    static let javascript = Language(lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\"", "'", "`"], multilineQuotes: ["`"], keywords: words(
        "const let var function return if else for while do switch case default break continue new this class extends super import export from as async await try catch finally throw typeof instanceof in of null undefined true false void delete yield static get set interface type enum implements private public protected readonly declare namespace abstract keyof"))

    static let python = Language(lineComments: ["#"], blockComments: [], quotes: ["\"", "'"], keywords: words(
        "def class return if elif else for while in not and or is import from as with try except finally raise pass break continue lambda yield None True False self async await global nonlocal assert del match case"))

    static let rust = Language(lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\""], keywords: words(
        "fn let mut const static struct enum impl trait pub use mod crate self Self super match if else loop while for in return break continue as ref move where type unsafe async await dyn true false Some None Ok Err"))

    static let ruby = Language(lineComments: ["#"], blockComments: [], quotes: ["\"", "'"], keywords: words(
        "def end class module if elsif else unless while until for in do return yield begin rescue ensure raise self nil true false and or not then case when require require_relative attr_reader attr_accessor private"))

    static let shell = Language(lineComments: ["#"], blockComments: [], quotes: ["\"", "'"], keywords: words(
        "if then else elif fi for while until do done case esac in function return local export readonly set unset exit true false source"))

    static let cFamily = Language(lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\"", "'"], keywords: words(
        "if else for while do switch case default break continue return struct class enum union typedef static const void int char float double long short unsigned signed bool boolean true false null nullptr NULL new delete this public private protected virtual override final import package namespace using template typename try catch throw throws fun val var when object interface extends implements sealed data suspend"))

    static let json = Language(lineComments: [], blockComments: [], quotes: ["\""], keywords: words("true false null"))

    static let config = Language(lineComments: ["#"], blockComments: [], quotes: ["\"", "'"], keywords: words("true false null yes no on off"))

    /// Only double quotes, since an apostrophe in page text would otherwise color the rest of its line.
    /// No `//` comments either, or every `https://` would start one.
    static let html = Language(lineComments: [], blockComments: [("<!--", "-->"), ("/*", "*/")], quotes: ["\""],
                               keywords: words("DOCTYPE doctype"), tagNames: true)

    static let markdown = Language(lineComments: [], blockComments: [], quotes: [], keywords: [], isMarkdown: true)

    static let css = Language(lineComments: [], blockComments: [("/*", "*/")], quotes: ["\"", "'"], keywords: words("important"))
}
