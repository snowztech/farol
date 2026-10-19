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

    /// Lines that have `query` in them, ignoring case, in the files under `folder`. At most `limit`, and a few per file.
    /// A checkout is searched with git, which skips what it ignores. Anywhere else, the same short walk as the file list.
    public static func search(_ query: String, in folder: String, limit: Int = 300) -> [Match] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return Git.repoRoot(of: folder) != nil ? grep(query, in: folder, limit: limit) : scan(query, in: folder, limit: limit)
    }

    static let perFile = 20

    static func grep(_ query: String, in folder: String, limit: Int) -> [Match] {
        // -z, so a name with a colon or an accent comes through as it is. Git fails with no match, which is no match here too.
        guard let output = try? Git.run(
            ["grep", "-n", "-z", "-I", "-i", "-F", "--untracked", "--exclude-standard", "--max-count=\(perFile)", "-e", query, "--", "."],
            in: folder, trimming: false) else { return [] }
        var matches: [Match] = []
        for record in output.split(separator: "\n") {
            let fields = record.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let line = Int(fields[1]) else { continue }
            matches.append(Match(path: String(fields[0]), line: line, text: shown(fields[2])))
            if matches.count == limit { break }
        }
        return matches
    }

    static func scan(_ query: String, in folder: String, limit: Int) -> [Match] {
        var matches: [Match] = []
        for path in Files.walk(folder) where !path.hasSuffix("/") {
            guard case .text(let text)? = try? Files.read(folder + "/" + path) else { continue }
            var found = 0
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.range(of: query, options: .caseInsensitive) != nil {
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
