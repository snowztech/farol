import Foundation

/// The review's search through the diffs it holds.
public enum DiffSearch {
    /// One place the search found: the row of the file's diff, the row's text, and the characters in it.
    public struct Match: Equatable, Sendable {
        public let path: String
        public let row: Int
        public let text: String
        public let range: NSRange

        public init(path: String, row: Int, text: String, range: NSRange) {
            self.path = path
            self.row = row
            self.text = text
            self.range = range
        }
    }

    public static func matches(in files: [(path: String, lines: [(row: Int, text: String)])], query: String,
                               options: FileSearch.Options, limit: Int) -> [Match] {
        var found: [Match] = []
        for file in files {
            for (row, text) in file.lines {
                for range in FileSearch.ranges(of: query, in: text, options: options) {
                    found.append(Match(path: file.path, row: row, text: text, range: NSRange(range, in: text)))
                    if found.count >= limit { return found }
                }
            }
        }
        return found
    }

    /// Where `match` went after the diff changed. Edits above it move its row, so it is found by its text, at the closest row.
    /// If that line is gone, the closest match left in its file. Nil when the file has none.
    public static func follow(_ match: Match, in found: [Match]) -> Int? {
        let file = found.indices.filter { found[$0].path == match.path }
        let same = file.filter { found[$0].text == match.text && found[$0].range == match.range }
        return (same.isEmpty ? file : same).min { abs(found[$0].row - match.row) < abs(found[$1].row - match.row) }
    }
}
