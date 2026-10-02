import Foundation

/// The words that changed inside modified lines, so a chunk shows what moved and not only which lines.
public enum InlineDiff {
    /// Past these sizes a chunk is a rewrite, and the token diff would cost more than it tells.
    public static let maxLineLength = 500
    public static let maxLines = 200
    /// Lines sharing less than this are different lines, and marking their words would be noise.
    public static let minShared = 0.4
    /// How far ahead a line looks for its ancestor when the chunk grew or shrank.
    static let window = 8

    /// Words, numbers, whitespace runs and single punctuation marks, in order.
    static func tokens(_ line: String) -> [Substring] {
        var tokens: [Substring] = []
        var index = line.startIndex
        while index < line.endIndex {
            let first = line[index]
            var end = line.index(after: index)
            func take(while keep: (Character) -> Bool) {
                while end < line.endIndex, keep(line[end]) { end = line.index(after: end) }
            }
            if first.isWhitespace {
                take { $0.isWhitespace }
            } else if first.isNumber {
                take { $0.isNumber || $0.isLetter || $0 == "." || $0 == "_" }
            } else if first.isLetter || first == "_" {
                take { $0.isLetter || $0.isNumber || $0 == "_" }
            }
            tokens.append(line[index..<end])
            index = end
        }
        return tokens
    }

    /// For each line of `changed`, the UTF-16 ranges that differ from its ancestor in `base`.
    /// A line with no close enough ancestor gets no ranges: the whole line is new.
    public static func changes(base: [String], changed: [String]) -> [[Range<Int>]] {
        var result = Array(repeating: [Range<Int>](), count: changed.count)
        guard !base.isEmpty, !changed.isEmpty, base.count <= maxLines, changed.count <= maxLines else { return result }
        if base.count == changed.count {
            for index in changed.indices {
                result[index] = compare(base[index], changed[index])?.ranges ?? []
            }
            return result
        }
        // Lines keep their order, so each one looks for its ancestor a little past the last match.
        var next = 0
        for index in changed.indices where next < base.count {
            var best: (line: Int, shared: Double, ranges: [Range<Int>])?
            for candidate in next..<min(base.count, next + window) {
                guard let match = compare(base[candidate], changed[index]) else { continue }
                if match.shared > best?.shared ?? 0 { best = (candidate, match.shared, match.ranges) }
            }
            if let best {
                result[index] = best.ranges
                next = best.line + 1
            }
        }
        return result
    }

    /// The changed ranges of `new` against `old`, or nil when the two lines are too different to pair.
    static func compare(_ old: String, _ new: String) -> (shared: Double, ranges: [Range<Int>])? {
        if old == new { return (1, []) }
        guard old.utf16.count <= maxLineLength, new.utf16.count <= maxLineLength else { return nil }
        let a = tokens(old), b = tokens(new)
        let inserted = Set(b.difference(from: a).insertions.map { change -> Int in
            if case .insert(let offset, _, _) = change { return offset }
            return -1
        })
        // Whitespace counts toward nothing, or every indented line would look alike.
        func weight(_ token: Substring) -> Int { token.first?.isWhitespace == true ? 0 : token.utf16.count }
        let total = a.reduce(0) { $0 + weight($1) } + b.reduce(0) { $0 + weight($1) }
        let kept = b.indices.filter { !inserted.contains($0) }.reduce(0) { $0 + weight(b[$1]) }
        guard total > 0 else { return nil }
        let shared = Double(2 * kept) / Double(total)
        guard shared >= minShared else { return nil }

        var ranges: [Range<Int>] = []
        var offset = 0
        var gap: Range<Int>?
        for (index, token) in b.enumerated() {
            let range = offset..<(offset + token.utf16.count)
            offset = range.upperBound
            if inserted.contains(index) {
                // Two changed words with only a space between read as one change.
                if let last = ranges.last, let gap, last.upperBound == gap.lowerBound, gap.upperBound == range.lowerBound {
                    ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
                } else if let last = ranges.last, last.upperBound == range.lowerBound {
                    ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
                } else {
                    ranges.append(range)
                }
                gap = nil
            } else {
                gap = token.first?.isWhitespace == true ? range : nil
            }
        }
        return (shared, ranges)
    }
}
