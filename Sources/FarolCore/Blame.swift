import Foundation

/// Who last changed each line of a file, from `git blame`.
public enum Blame {
    public struct Line: Equatable {
        public let hash: String
        public let author: String
        public let date: Date
        public let summary: String

        /// Git blames lines that aren't committed yet on an all-zero hash.
        public var isCommitted: Bool { hash.contains { $0 != "0" } }
        public var shortHash: String { String(hash.prefix(7)) }
    }

    /// One entry per line of the file, in order. Nil when git can't blame it, as for a file git doesn't track.
    public static func lines(of path: String) -> [Line]? {
        let url = URL(fileURLWithPath: path)
        guard let output = try? Git.run(["blame", "--porcelain", "--", url.lastPathComponent],
                                        in: url.deletingLastPathComponent().path, trimming: false) else { return nil }
        return parse(output)
    }

    /// The porcelain format gives a commit's details only the first time it comes up, then just a header for each of its other lines.
    static func parse(_ output: String) -> [Line] {
        var commits: [String: (author: String, date: Date, summary: String)] = [:]
        var lines: [Line] = []
        var hash = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\t") {
                guard let known = commits[hash] else { continue }
                lines.append(Line(hash: hash, author: known.author, date: known.date, summary: known.summary))
                continue
            }
            let fields = line.split(separator: " ", maxSplits: 3)
            if fields.count >= 3, fields[0].count == 40, fields[0].allSatisfy(\.isHexDigit) {
                hash = String(fields[0])
                if commits[hash] == nil { commits[hash] = ("", Date(timeIntervalSince1970: 0), "") }
            } else if line.hasPrefix("author ") {
                commits[hash]?.author = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("author-time "), let seconds = TimeInterval(line.dropFirst("author-time ".count)) {
                commits[hash]?.date = Date(timeIntervalSince1970: seconds)
            } else if line.hasPrefix("summary ") {
                commits[hash]?.summary = String(line.dropFirst("summary ".count))
            }
        }
        return lines
    }
}
