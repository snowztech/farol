import Foundation

/// Who last changed each line of a file, from `git blame`.
public enum Blame {
    public struct Line: Equatable {
        public let hash: String
        public let author: String
        public let email: String
        public let date: Date
        public let summary: String

        /// Git blames lines that aren't committed yet on an all-zero hash.
        public var isCommitted: Bool { hash.contains { $0 != "0" } }
        public var shortHash: String { String(hash.prefix(7)) }
    }

    /// How long ago, as short as a narrow column needs: "4h", "2w", "3mo".
    public static func age(of date: Date, now: Date = Date()) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        let days = minutes / (60 * 24)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if days < 1 { return "\(minutes / 60)h" }
        if days < 7 { return "\(days)d" }
        if days < 30 { return "\(days / 7)w" }
        if days < 365 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }

    /// One entry per line of the saved file, in order. Nil when git can't blame it, as for a file it doesn't track.
    public static func lines(of path: String) -> [Line]? {
        let url = URL(fileURLWithPath: path)
        let output = try? Git.run(["blame", "--porcelain", "--", url.lastPathComponent],
                                  in: url.deletingLastPathComponent().path, trimming: false)
        return output.map(parse)
    }

    /// The porcelain format gives a commit's details only the first time it comes up, then just a header for each of its other lines.
    static func parse(_ output: String) -> [Line] {
        var commits: [String: (author: String, email: String, date: Date, summary: String)] = [:]
        var lines: [Line] = []
        var hash = ""
        // A file's own "\\r\\n" reaches here too, and Swift reads it as one character that isn't "\\n".
        for line in output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            if line.hasPrefix("\t") {
                guard let known = commits[hash] else { continue }
                lines.append(Line(hash: hash, author: known.author, email: known.email, date: known.date, summary: known.summary))
                continue
            }
            let fields = line.split(separator: " ", maxSplits: 3)
            if fields.count >= 3, fields[0].count == 40, fields[0].allSatisfy(\.isHexDigit) {
                hash = String(fields[0])
                if commits[hash] == nil { commits[hash] = ("", "", Date(timeIntervalSince1970: 0), "") }
            } else if line.hasPrefix("author ") {
                commits[hash]?.author = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("author-mail ") {
                commits[hash]?.email = line.dropFirst("author-mail ".count).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            } else if line.hasPrefix("author-time "), let seconds = TimeInterval(line.dropFirst("author-time ".count)) {
                commits[hash]?.date = Date(timeIntervalSince1970: seconds)
            } else if line.hasPrefix("summary ") {
                commits[hash]?.summary = String(line.dropFirst("summary ".count))
            }
        }
        return lines
    }
}
