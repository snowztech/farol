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

        /// Which index a file reads: Vue and script files import from each other, so they share one.
        var family: String {
            switch self {
            case .swift: "swift"
            case .go: "go"
            case .script, .vue: "web"
            }
        }

        /// Words a declaration pattern can catch that only start a statement, like Go's `\treturn err` read as a field.
        var keywords: Set<String> {
            switch self {
            case .swift: ["let", "var", "case", "in", "if", "guard", "while", "for", "return", "self", "super"]
            case .go: ["return", "go", "defer", "break", "continue", "goto", "fallthrough", "case", "default", "var", "const",
                       "type", "func", "package", "import", "if", "else", "for", "switch", "select", "range", "chan", "map",
                       "struct", "interface"]
            case .script, .vue: ["if", "for", "while", "switch", "catch", "function", "return", "with", "do", "else", "new",
                                 "typeof", "await", "yield", "constructor"]
            }
        }

        /// Lines that declare `name`, an escaped word or, for the index, a pattern for any name. `exported` is one with a capital, for Go's const blocks.
        /// `shared` can be anywhere in the project. `local` binds a name inside a function, so it is only looked for in the clicked file.
        func declarations(of name: String, exported: String?) -> (shared: [String], local: [String]) {
            switch self {
            case .swift:
                let initializer = #"^\s*(?:\w+\s+)*"# + (name == "init" ? "init" : "(?<n>init)") + #"\s*[?!]?\s*\("#
                if name == "init" { return ([initializer], []) }
                let modifiers = #"(?:@\w+(?:\([^)]*\))?\s+|(?:public|private|fileprivate|internal|open|package|static|final|override|lazy|weak|unowned|mutating|nonmutating|required|convenience|nonisolated|indirect)\s+)*"#
                return ([
                    initializer,
                    #"\b(?:func|class|struct|enum|protocol|actor|typealias|associatedtype|macro)\s+\#(name)\b"#,
                    // A property: at the top of the file or one level into a type. Deeper, it is a function's own.
                    #"^(?: {0,4}|\t?)"# + modifiers + #"(?:var|let)\s+\#(name)\b"#,
                    // An enum case, alone or among others on the same line.
                    #"\bcase\s+(?:[A-Za-z_]\w*(?:\([^)]*\))?\s*,\s*)*\#(name)\b"#,
                ], [
                    #"^\s+"# + modifiers + #"(?:var|let)\s+\#(name)\b"#,
                    // Bound by if, guard or while, among other conditions on the line.
                    #"\b(?:if|guard|while)\b.*\b(?:let|var)\s+\#(name)\b"#,
                    #"\bfor\s+(?:case\s+)?(?:let\s+|var\s+)?\(?(?:\w+\s*,\s*)*\#(name)\s*(?:,\s*\w+\s*)*\)?\s+in\b"#,
                ])
            case .go:
                var shared = [
                    // A function, or a method after its receiver.
                    #"^func\s+(?:\([^)]*\)\s*)?\#(name)\b"#,
                    #"^type\s+\#(name)\b"#,
                    #"^(?:var|const)\s+\#(name)\b"#,
                    // A struct field: the name, its type, then a tag, a comment or nothing. A statement never reads like that.
                    #"^\t+\#(name)\s+[*\[\]\w.]+\s*(?:`|//|$)"#,
                    // An interface's method, told from a call by the result type after it.
                    #"^\t+\#(name)\([^)]*\)\s*[\w*(\[]"#,
                ]
                // Inside a const or var block. Only exported names, which tell them from a later assignment to a variable.
                // That includes a constant that only continues the one above, like the second of two after iota.
                if let exported {
                    shared.append(#"^\t\#(exported)\s+(?:[\w.\[\]*]+\s*)?="#)
                    shared.append(#"^\t\#(exported)\s*(?://.*)?$"#)
                }
                return (shared, [
                    #"^\s+(?:var|const)\s+\#(name)\b"#,
                    // From :=, alone or among others, as in a range loop.
                    #"\b(?:\w+\s*,\s*)*\#(name)\s*(?:,\s*\w+\s*)*:="#,
                ])
            case .script, .vue:
                return ([
                    #"\bfunction\s*\*?\s*\#(name)\b"#,
                    #"\b(?:class|interface|enum|type|namespace)\s+\#(name)\b"#,
                    #"^(?:export\s+(?:default\s+)?)?(?:declare\s+)?(?:const|let|var)\s+\#(name)\b"#,
                    // A method written in an object or a class: name(args) { ... }
                    #"^\s*(?:(?:async|static|get|set|public|private|protected|readonly|override)\s+)*\#(name)\s*(?:<[^>]*>)?\([^)]*\)\s*(?::\s*[^{=]+)?\{"#,
                    // A method given as a property: name: function or name: (args) =>
                    #"^\s*\#(name)\s*:\s*(?:async\s*)?(?:function\b|\()"#,
                ], [
                    #"\b(?:const|let|var)\s+\#(name)\b"#,
                ])
            }
        }
    }

    /// Which index serves a file, or nil for a language there is none for. Files in one family find each other's declarations.
    public static func family(of path: String) -> String? { Language(path: path)?.family }

    /// The name under `index`, a UTF-16 offset in `text`, or nil when it is on something that isn't one.
    /// `hyphens` is for Vue templates, where a component is written <my-button>.
    public static func word(in text: String, at index: Int, hyphens: Bool = false) -> String? {
        wordRange(in: text, at: index, hyphens: hyphens).map { (text as NSString).substring(with: $0) }
    }

    /// Whether the name at `range` is reached through another value, like `e.provider.Run`, and not `self.run` or `this.run`.
    public static func isMember(in text: String, at range: NSRange) -> Bool {
        let string = text as NSString
        guard range.location > 0, string.character(at: range.location - 1) == 0x2E else { return false }
        let before = string.substring(to: range.location - 1)
        return !(before.hasSuffix("self") || before.hasSuffix("this")) || before.hasSuffix(".self") || before.hasSuffix(".this")
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

    /// Every declaration in a checkout for one family of languages, by name, so a lookup under the mouse is instant.
    /// Built with one search of the project, which takes a moment: build it off the main thread, and again now and then.
    public struct Index: Sendable {
        public let folder: String
        let names: [String: [FileSearch.Match]]
        /// For a Vue component used as a tag, which is found by its file.
        let vueFiles: [String]

        /// Empty, for a file no language here reads.
        public static func build(for path: String, in folder: String) -> Index {
            guard let language = Language(path: path) else { return Index(folder: folder, names: [:], vueFiles: []) }
            let shared = language.declarations(of: #"(?<n>[A-Za-z_$][\w$]*)"#, exported: #"(?<n>[A-Z]\w*)"#).shared
            let extractors = shared.compactMap { try? NSRegularExpression(pattern: $0) }
            let patterns = shared.map { $0.replacingOccurrences(of: "(?<n>", with: "(?:") }
            let keywords = language.keywords
            var names: [String: [FileSearch.Match]] = [:]
            for hit in lines(matching: patterns, in: folder, files: language.globs) {
                let line = hit.text as NSString
                var found: Set<String> = []
                for extractor in extractors {
                    for match in extractor.matches(in: hit.text, range: NSRange(location: 0, length: line.length)) {
                        let range = match.range(withName: "n")
                        if range.location != NSNotFound { found.insert(line.substring(with: range)) }
                    }
                }
                if language == .swift { found.formUnion(enumCases(in: hit.text)) }
                let match = FileSearch.Match(path: hit.path, line: hit.line, text: shown(hit.text))
                for name in found.subtracting(keywords) { names[name, default: []].append(match) }
            }
            let vue = language.family == "web" ? files(in: folder, matching: ["*.vue"]) : []
            return Index(folder: folder, names: names, vueFiles: vue)
        }

        /// Where `word`, clicked in the file at `path` whose text is `text`, is declared. Paths are relative to the folder.
        /// The clicked file comes first, then its folder, so the nearest answer is the first.
        public func find(_ word: String, from path: String, text: String, limit: Int = 30) -> [FileSearch.Match] {
            guard let language = Language(path: path) else { return [] }
            let here = path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path
            var found: [FileSearch.Match] = []
            if language == .vue { found += Definitions.components(named: word, among: vueFiles) }
            found += Definitions.locals(word, in: text, language: language, path: here)
            found += names[word] ?? []
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
    }

    /// Where `word`, clicked in the file at `path`, is declared in the project under `folder`. Builds a whole index for one name, for tests.
    static func find(_ word: String, from path: String, in folder: String, limit: Int = 30) -> [FileSearch.Match] {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return Index.build(for: path, in: folder).find(word, from: path, text: text, limit: limit)
    }

    /// Variables bound inside a function, read from the text open in the pane, so unsaved edits count too.
    static func locals(_ word: String, in text: String, language: Language, path: String) -> [FileSearch.Match] {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let local = language.declarations(of: escaped, exported: word.first?.isUppercase == true ? escaped : nil).local
        guard !local.isEmpty,
              let expression = try? NSRegularExpression(pattern: local.map { "(?:\($0))" }.joined(separator: "|"), options: .anchorsMatchLines)
        else { return [] }
        let string = text as NSString
        var matches: [FileSearch.Match] = []
        var line = 1
        var counted = 0
        var lastLine = -1
        for match in expression.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            // Counted on from the last match, so a long file is read once.
            while counted < match.range.location {
                let next = string.range(of: "\n", range: NSRange(location: counted, length: match.range.location - counted))
                guard next.location != NSNotFound else { break }
                line += 1
                counted = NSMaxRange(next)
            }
            counted = max(counted, match.range.location)
            guard line != lastLine else { continue }
            lastLine = line
            let text = string.substring(with: string.lineRange(for: match.range))
            matches.append(FileSearch.Match(path: path, line: line, text: shown(text)))
        }
        return matches
    }

    /// Each name in an enum's case line, `case a, b(Int), c = 3`. A switch's case ends in a colon, which a declaration never has.
    static func enumCases(in line: String) -> [String] {
        guard let start = line.range(of: #"^\s*(?:(?:indirect|public|private|fileprivate|internal|package)\s+)*case\s+"#, options: .regularExpression)
        else { return [] }
        var rest = String(line[start.upperBound...])
        if let comment = rest.range(of: "//") { rest = String(rest[..<comment.lowerBound]) }
        // What is in parentheses or after = is the case's values, not more names.
        var depth = 0
        rest = String(rest.filter { character in
            if character == "(" { depth += 1 } else if character == ")" { depth -= 1; return false }
            return depth == 0
        })
        guard !rest.contains(":") else { return [] }
        return rest.split(separator: ",").compactMap { part in
            let name = part.split(separator: "=").first?.trimmingCharacters(in: .whitespaces) ?? ""
            return name.range(of: #"^[A-Za-z_]\w*$"#, options: .regularExpression) != nil ? name : nil
        }
    }

    /// The lines in the project's files that match any of `patterns`, all of them, since the index needs every declaration.
    /// One -e each: joined into one alternation, Perl's engine can't skip ahead and the search takes six times as long.
    static func lines(matching patterns: [String], in folder: String, files globs: [String]) -> [(path: String, line: Int, text: String)] {
        if !FileSearch.walks(folder),
           let output = try? Git.run(["grep", "-n", "-z", "-I", "-P", "--untracked", "--exclude-standard"] + patterns.flatMap { ["-e", $0] } + ["--"] + globs,
                                     in: folder, trimming: false) {
            return output.split(separator: "\n").compactMap { record in
                let fields = record.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3, let line = Int(fields[1]) else { return nil }
                return (String(fields[0]), line, String(fields[2]))
            }
        }
        // Outside git, or a git without Perl's expressions: the files are read here.
        guard let expression = try? NSRegularExpression(pattern: patterns.map { "(?:\($0))" }.joined(separator: "|")) else { return [] }
        var found: [(path: String, line: Int, text: String)] = []
        for path in files(in: folder, matching: globs) {
            guard case .text(let text)? = try? Files.read(folder + "/" + path) else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(line)
                if expression.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                    found.append((path, index + 1, line))
                }
            }
        }
        return found
    }

    /// The project's files matching `globs`, relative to the folder: git's list in a checkout, a short walk outside one.
    static func files(in folder: String, matching globs: [String]) -> [String] {
        if FileSearch.walks(folder) {
            return Files.walk(folder, depth: FileSearch.walkDepth).filter { path in
                !path.hasSuffix("/") && globs.contains { fnmatch($0, (path as NSString).lastPathComponent, 0) == 0 }
            }
        }
        let listed = (try? Git.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--"] + globs, in: folder, trimming: false)) ?? ""
        return listed.split(separator: "\0").map(String.init)
    }

    /// A line as a row shows it: without its indent, and cut, since a minified file is one line of thousands of characters.
    static func shown<S: StringProtocol>(_ line: S) -> String {
        let text = line.drop { $0 == " " || $0 == "\t" }.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 240 ? String(text.prefix(240)) + "…" : text
    }

    /// The answer to open without asking, or nil to let you pick. Declared once in the clicked file, it is that one, as with a private helper.
    /// Declared there more than once, it is a local, and the nearest one above the click is in scope.
    /// Through another value, as in `e.provider.Run`, the clicked file is no hint, so several answers ask.
    public static func best(_ found: [FileSearch.Match], from path: String, in folder: String, line: Int,
                            member: Bool = false) -> FileSearch.Match? {
        if found.count == 1 { return found[0] }
        if member { return nil }
        let local = found.filter { folder + "/" + $0.path == path }
        if local.count == 1 { return local[0] }
        return local.filter { $0.line < line }.max { $0.line < $1.line }
    }

    /// A Vue component used as a tag, found by its file: MyButton or my-button is MyButton.vue, my-button.vue or MyButton/index.vue.
    static func components(named word: String, among files: [String]) -> [FileSearch.Match] {
        let pascal = word.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        guard pascal.first?.isUppercase == true, word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return [] }
        var kebab = ""
        for character in pascal {
            if character.isUppercase, !kebab.isEmpty { kebab += "-" }
            kebab += character.lowercased()
        }
        let wanted: Set<String> = ["\(pascal).vue", "\(kebab).vue", "\(pascal)/index.vue", "\(kebab)/index.vue"]
        return files.filter { file in wanted.contains { file == $0 || file.hasSuffix("/" + $0) } }
            .map { FileSearch.Match(path: $0, line: 1, text: ($0 as NSString).lastPathComponent) }
    }
}
