import Foundation

/// Which lines of a file differ from its last commit, for the marks beside the line numbers.
public enum LineChanges {
    public enum Kind: Equatable { case added, modified, deleted }

    /// One mark, on a line of the new text from 0.
    /// A deletion sits on the line that follows what was removed, or one past the last line when the end of the file went.
    public struct Mark: Equatable {
        public let line: Int
        public let kind: Kind

        public init(line: Int, kind: Kind) {
            self.line = line
            self.kind = kind
        }
    }

    /// Past this many lines on either side the marks are skipped, since a diff that big would hold up the pane for little.
    public static let limit = 50_000

    /// Lines removed and added in one place count as modified, as editors show it. Only added are added, only removed leave a deletion mark.
    public static func marks(from old: String, to new: String) -> [Mark] {
        let before = lines(old), after = lines(new)
        guard before.count <= limit, after.count <= limit, before != after else { return [] }
        let difference = after.difference(from: before)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var marks: [Mark] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            var gone = 0, added = 0
            while removed.contains(i + gone) { gone += 1 }
            while inserted.contains(j + added) { added += 1 }
            if gone == 0 && added == 0 {
                i += 1
                j += 1
                continue
            }
            if added == 0 {
                marks.append(Mark(line: j, kind: .deleted))
            } else {
                for line in j..<(j + added) { marks.append(Mark(line: line, kind: gone > 0 ? .modified : .added)) }
            }
            i += gone
            j += added
        }
        return marks
    }

    /// The file as of the last commit, to compare against. Empty for a file git doesn't have yet, so every line shows as added.
    /// Nil for one git ignores, which has nothing to compare with.
    public static func base(of path: String) -> String? {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if let committed = try? Git.run(["show", "HEAD:./\(name)"], in: directory, trimming: false) { return committed }
        // check-ignore succeeds only for an ignored file.
        return (try? Git.run(["check-ignore", "--quiet", name], in: directory)) == nil ? "" : nil
    }

    /// A file's lines without their breaks. A last line break starts no line of its own, as the numbers beside the text count them.
    static func lines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }
}
