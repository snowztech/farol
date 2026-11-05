import Foundation

/// Finds where a name is defined, for ⌘-click in a file. There is no language server.
/// The project is searched for lines that declare it, with a few patterns per language, so a name can have several answers.
public enum Definitions {
    /// What a file's extension says about where to look and what a declaration looks like.
    enum Language {
        case swift, go
        /// JavaScript and TypeScript, which Vue files import from and share their script syntax with.
        case script
        case vue

        init?(path: String) {
            switch URL(fileURLWithPath: path).pathExtension.lowercased() {
            case "swift": self = .swift
            case "go": self = .go
            case "vue": self = .vue
            case "ts", "tsx", "js", "jsx", "mjs", "cjs": self = .script
            default: return nil
            }
        }

        /// The files a definition can be in. A Vue component's script comes from a script file as often as from a Vue one.
        var globs: [String] {
            switch self {
            case .swift: ["*.swift"]
            case .go: ["*.go"]
            case .script, .vue: ["*.vue", "*.ts", "*.tsx", "*.js", "*.jsx", "*.mjs", "*.cjs"]
            }
        }

        /// Regular expressions for a line that declares `name`, already escaped. Perl's syntax, which the Mac's engine reads the same.
        func declarations(of name: String) -> [String] {
            switch self {
            case .swift:
                var patterns = [
                    #"\b(?:func|class|struct|enum|protocol|actor|typealias|associatedtype|macro)\s+\#(name)\b"#,
                    // A property or a variable, after any modifiers and attributes.
                    #"^\s*(?:@\w+(?:\([^)]*\))?\s+|(?:public|private|fileprivate|internal|open|package|static|final|override|lazy|weak|unowned|mutating|nonmutating|required|convenience|nonisolated|indirect)\s+)*(?:var|let)\s+\#(name)\b"#,
                    // An enum case, alone or among others on the same line.
                    #"\bcase\s+(?:[A-Za-z_]\w*(?:\([^)]*\))?\s*,\s*)*\#(name)\b"#,
                ]
                if name == "init" { patterns = [#"^\s*(?:\w+\s+)*init\s*[?!]?\s*\("#] }
                return patterns
            case .go:
                var patterns = [
                    // A function, or a method after its receiver.
                    #"^func\s+(?:\([^)]*\)\s*)?\#(name)\b"#,
                    #"^type\s+\#(name)\b"#,
                    #"^\s*(?:var|const)\s+\#(name)\b"#,
                ]
                // Inside a const or var block. Only exported names, which tell them from a later assignment to a variable.
                // That includes a constant that only continues the one above, like the second of two after iota.
                if name.first?.isUppercase == true {
                    patterns.append(#"^\t\#(name)\s+(?:[\w.\[\]*]+\s*)?="#)
                    patterns.append(#"^\t\#(name)\s*(?://.*)?$"#)
                }
                return patterns
            case .script, .vue:
                return [
                    #"\bfunction\s*\*?\s*\#(name)\b"#,
                    #"\b(?:class|interface|enum|type|namespace)\s+\#(name)\b"#,
                    #"\b(?:const|let|var)\s+\#(name)\b"#,
                    // A method written in an object or a class: name(args) { ... }
                    #"^\s*(?:(?:async|static|get|set|public|private|protected|readonly|override)\s+)*\#(name)\s*(?:<[^>]*>)?\([^)]*\)\s*(?::\s*[^{=]+)?\{"#,
                    // A method given as a property: name: function or name: (args) =>
                    #"^\s*\#(name)\s*:\s*(?:async\s*)?(?:function\b|\()"#,
                ]
            }
        }
    }

    /// The name under `index`, a UTF-16 offset in `text`, or nil when it is on something that isn't one.
    /// `hyphens` is for Vue templates, where a component is written <my-button>.
    public static func word(in text: String, at index: Int, hyphens: Bool = false) -> String? {
        wordRange(in: text, at: index, hyphens: hyphens).map { (text as NSString).substring(with: $0) }
    }

    /// Where that name is in `text`, for coloring all of it.
    public static func wordRange(in text: String, at index: Int, hyphens: Bool = false) -> NSRange? {
        let string = text as NSString
        guard string.length > 0 else { return nil }
        func part(_ unit: Int) -> Bool {
            guard unit >= 0, unit < string.length, let scalar = Unicode.Scalar(string.character(at: unit)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$" || (hyphens && scalar == "-")
        }
        // A click after the last letter of a name, as at the end of a line, still means that name.
        var start = min(index, string.length)
        if !part(start) { start -= 1 }
        guard part(start) else { return nil }
        var end = start
        while part(start - 1) { start -= 1 }
        while part(end + 1) { end += 1 }
        // A hyphen that only joins the name to what is next to it, as in "a -b", isn't part of it.
        while start <= end, string.character(at: start) == 0x2D { start += 1 }
        while end >= start, string.character(at: end) == 0x2D { end -= 1 }
        guard start <= end, let first = Unicode.Scalar(string.character(at: start)), !CharacterSet.decimalDigits.contains(first) else { return nil }
        return NSRange(location: start, length: end - start + 1)
    }

    /// Where `word`, clicked in the file at `path`, is declared in the project under `folder`. Paths are relative to `folder`.
    /// The clicked file comes first, then its folder, so the nearest answer is the first. Takes a moment: call it off the main thread.
    public static func find(_ word: String, from path: String, in folder: String, limit: Int = 30) -> [FileSearch.Match] {
        guard let language = Language(path: path) else { return [] }
        var found: [FileSearch.Match] = []
        if language == .vue { found += components(named: word, in: folder) }
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let query = language.declarations(of: escaped).map { "(?:\($0))" }.joined(separator: "|")
        let options = FileSearch.Options(caseSensitive: true, regex: true, files: language.globs)
        found += FileSearch.search(query, in: folder, options: options, limit: 200)

        let here = path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path
        let nearby = (here as NSString).deletingLastPathComponent
        func rank(_ match: FileSearch.Match) -> Int {
            if match.path == here { return 0 }
            return (match.path as NSString).deletingLastPathComponent == nearby ? 1 : 2
        }
        // Sorted by distance only, so the order inside each is the one the search gave.
        let ranked = found.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        var seen: Set<FileSearch.Match> = []
        return Array(ranked.filter { seen.insert($0).inserted }.prefix(limit))
    }

    /// A Vue component used as a tag, found by its file: MyButton or my-button is MyButton.vue, my-button.vue or MyButton/index.vue.
    static func components(named word: String, in folder: String) -> [FileSearch.Match] {
        let pascal = word.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        guard pascal.first?.isUppercase == true, word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return [] }
        var kebab = ""
        for character in pascal {
            if character.isUppercase, !kebab.isEmpty { kebab += "-" }
            kebab += character.lowercased()
        }
        let wanted: Set<String> = ["\(pascal).vue", "\(kebab).vue", "\(pascal)/index.vue", "\(kebab)/index.vue"]
        let files: [String]
        if FileSearch.walks(folder) {
            files = Files.walk(folder, depth: FileSearch.walkDepth).filter { !$0.hasSuffix("/") }
        } else {
            let listed = (try? Git.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.vue"], in: folder, trimming: false)) ?? ""
            files = listed.split(separator: "\0").map(String.init)
        }
        return files.filter { file in wanted.contains { file == $0 || file.hasSuffix("/" + $0) } }
            .map { FileSearch.Match(path: $0, line: 1, text: ($0 as NSString).lastPathComponent) }
    }
}
