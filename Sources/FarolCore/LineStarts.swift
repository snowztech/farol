import Foundation

/// Where each line of a text starts, as UTF-16 offsets, kept up to date edit by edit.
/// A line break at the very end starts no line, as the gutter counts them.
public struct LineStarts: Equatable {
    public private(set) var starts: [Int] = [0]

    public init() {}

    public init(_ text: NSString) {
        starts = [0] + Self.scan(text, from: 0, through: text.length)
    }

    /// Reads again only the edited lines and shifts the rest, so a keystroke costs the same in a 2 MB file as in a small one.
    /// `range` is where the edit is in the new text, as a text storage reports it.
    public mutating func edit(_ range: NSRange, changeInLength delta: Int, in text: NSString) {
        let oldEnd = NSMaxRange(range) - delta
        // From the line before, since an edit can join a \r to the \n that follows it.
        let first = max(0, line(atOrBefore: range.location) - 1)
        var kept = first + 1
        while kept < starts.count, starts[kept] <= oldEnd { kept += 1 }
        let tail = starts[kept...].map { $0 + delta }
        starts = Array(starts[...first]) + Self.scan(text, from: starts[first], through: NSMaxRange(range)) + tail
    }

    /// The line holding `location`, from 0.
    public func line(atOrBefore location: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The starts after `from` up to `end`, leaving out one at the very end of the text.
    private static func scan(_ text: NSString, from: Int, through end: Int) -> [Int] {
        var found: [Int] = []
        var index = from
        while index < text.length {
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            guard index <= end, index < text.length else { break }
            found.append(index)
        }
        return found
    }
}
