import Foundation

/// Text found in the files under a folder, for Find in Files.
public enum FileSearch {
    public struct Match: Equatable, Hashable, Sendable {
        /// Relative to the folder searched.
        public let path: String
        public let line: Int
        /// The line without its indent, cut to fit a row.
        public let text: String
    }

    public struct Options: Equatable, Sendable {
        /// Off, "Token" finds "token" too.
        public var caseSensitive: Bool
        /// The query as a whole word only, so "id" skips "width".
        public var wholeWord: Bool
        /// The query is a regular expression. Git reads it as an extended one, and the Mac's own engine marks it in the row.
        /// The two agree on the common parts: classes, groups, alternatives, repeats and anchors.
        public var regex: Bool
        /// Which files, as globs on the path: `*.swift` keeps only those, `!*Tests*` leaves those out. Empty is every file.
        public var files: [String]

        public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false, files: [String] = []) {
            self.caseSensitive = caseSensitive
            self.wholeWord = wholeWord
            self.regex = regex
            self.files = files
        }

        /// What is typed in the files field, like `*.swift, !*Tests*`, split on commas and spaces.
        public static func files(from text: String) -> [String] {
            text.split { $0 == "," || $0 == " " }.map(String.init)
        }

        /// The same globs as git reads them: a star crosses folders, so `*.swift` is any Swift file at any depth.
        func keeps(_ path: String) -> Bool {
            let included = files.filter { !$0.hasPrefix("!") }
            let excluded = files.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
            return (included.isEmpty || included.contains { fnmatch($0, path, 0) == 0 })
                && !excluded.contains { fnmatch($0, path, 0) == 0 }
        }

        var pathspecs: [String] {
            let included = files.filter { !$0.hasPrefix("!") && !$0.isEmpty }
            let excluded = files.filter { $0.hasPrefix("!") && $0.count > 1 }.map { ":(exclude)" + $0.dropFirst() }
            return (included.isEmpty ? ["."] : included) + excluded
        }
    }

    /// One search, which a newer one can stop: typing on in a big checkout would otherwise leave a git grep running per key.
    public final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var stopped = false

        public init() {}

        public var isCancelled: Bool { lock.withLock { stopped } }

        public func cancel() {
            lock.withLock {
                stopped = true
                if process?.isRunning == true { process?.terminate() }
            }
        }

        /// A process started after the cancel is stopped at once.
        func adopt(_ process: Process) {
            lock.withLock {
                self.process = process
                if stopped { process.terminate() }
            }
        }
    }

    /// Lines that have `query` in them in the files under `folder`. At most `limit`, and `perFile` per file.
    /// A checkout is searched with git, which skips what it ignores. Anywhere else, the same short walk as the file list.
    public static func search(_ query: String, in folder: String, options: Options = Options(), limit: Int = 300, job: Job = Job()) -> [Match] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return walks(folder)
            ? scan(query, in: folder, options: options, limit: limit, job: job) : grep(query, in: folder, options: options, limit: limit, job: job)
    }

    /// How many folders down the walk outside git goes, so a search there can miss deeper files and has to say so.
    public static let walkDepth = 3

    /// The folder isn't in a git checkout, so its files come from the walk rather than git.
    public static func walks(_ folder: String) -> Bool { Git.repoRoot(of: folder) == nil }

    /// Where `query` is in `line`, the way the search found it, so a row can mark exactly that.
    public static func ranges(of query: String, in line: String, options: Options) -> [Range<String.Index>] {
        matcher(query, options)?(line) ?? []
    }

    /// False for a regular expression that does not compile, which finds nothing and says so rather than looking empty.
    public static func isValid(_ query: String, options: Options) -> Bool {
        !options.regex || matcher(query, options) != nil
    }

    /// Built once per search, since compiling the expression for every line of every file would be most of the work.
    static func matcher(_ query: String, _ options: Options) -> ((String) -> [Range<String.Index>])? {
        guard !query.isEmpty else { return { _ in [] } }
        let find: (String) -> [Range<String.Index>]
        if options.regex {
            guard let expression = try? NSRegularExpression(pattern: query, options: options.caseSensitive ? [] : .caseInsensitive) else { return nil }
            find = { line in
                expression.matches(in: line, range: NSRange(line.startIndex..., in: line))
                    .compactMap { Range($0.range, in: line) }.filter { !$0.isEmpty }
            }
        } else {
            find = { line in
                var found: [Range<String.Index>] = []
                var rest = line.startIndex..<line.endIndex
                while let range = line.range(of: query, options: options.caseSensitive ? [] : .caseInsensitive, range: rest) {
                    found.append(range)
                    rest = range.upperBound..<line.endIndex
                }
                return found
            }
        }
        guard options.wholeWord else { return find }
        // Git's -w: a word character neither just before nor just after.
        return { line in
            find(line).filter { range in
                let before = range.lowerBound == line.startIndex ? nil : line[line.index(before: range.lowerBound)]
                let after = range.upperBound == line.endIndex ? nil : line[range.upperBound]
                return !isWord(before) && !isWord(after)
            }
        }
    }

    private static func isWord(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character == "_" || character.isLetter || character.isNumber
    }

    /// A file with more matching lines shows only these, so one log full of a word doesn't push out every other file.
    public static let perFile = 20

    static func grep(_ query: String, in folder: String, options: Options, limit: Int, job: Job) -> [Match] {
        func run(_ syntax: String) throws -> String {
            let flags = [syntax] + (options.caseSensitive ? [] : ["-i"]) + (options.wholeWord ? ["-w"] : [])
            // -z, so a name with a colon or an accent comes through as it is.
            return try Git.run(
                ["grep", "-n", "-z", "-I", "--untracked", "--exclude-standard", "--max-count=\(perFile)"] + flags + ["-e", query, "--"] + options.pathspecs,
                in: folder, trimming: false, started: job.adopt)
        }
        // Perl's syntax, like the NSRegularExpression that checks and marks the query, so \d or \b mean the same to both.
        // POSIX -E reads them otherwise, and is only for a git built without Perl's. Git fails with no match, which is no match here too.
        let output: String
        do {
            output = try run(options.regex ? "-P" : "-F")
        } catch let error where options.regex && "\(error)".localizedCaseInsensitiveContains("perl") {
            guard let posix = try? run("-E") else { return [] }
            output = posix
        } catch {
            return []
        }
        var matches: [Match] = []
        for record in output.split(separator: "\n") {
            let fields = record.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let line = Int(fields[1]) else { continue }
            matches.append(Match(path: String(fields[0]), line: line, text: shown(fields[2])))
            if matches.count == limit { break }
        }
        return matches
    }

    static func scan(_ query: String, in folder: String, options: Options, limit: Int, job: Job) -> [Match] {
        guard let matcher = matcher(query, options) else { return [] }
        var matches: [Match] = []
        for path in Files.walk(folder, depth: walkDepth) where !path.hasSuffix("/") && options.keeps(path) {
            if job.isCancelled { return [] }
            guard case .text(let text)? = try? Files.read(folder + "/" + path) else { continue }
            var found = 0
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !matcher(String(line)).isEmpty {
                matches.append(Match(path: path, line: index + 1, text: shown(line)))
                found += 1
                if matches.count == limit { return matches }
                if found == perFile { break }
            }
        }
        return matches
    }

    /// A minified file is one line of thousands of characters, and a row only shows the start of it.
    private static func shown(_ line: Substring) -> String {
        let text = line.drop { $0 == " " || $0 == "\t" }.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 240 ? String(text.prefix(240)) + "…" : text
    }
}
