import Foundation

/// JSON as people write it, with comments and trailing commas allowed, like tsconfig.json or VS Code settings.
public enum JSONFormat {
    /// Where the text stops being JSON, like "line 1, column 9", or nil when it is JSON.
    public static func problem(_ text: String) -> String? {
        do {
            _ = try JSONSerialization.jsonObject(with: Data(strict(Array(text.utf8))), options: .fragmentsAllowed)
            return nil
        } catch {
            let detail = (error as NSError).userInfo["NSDebugDescription"] as? String ?? ""
            return detail.range(of: #"line \d+, column \d+"#, options: .regularExpression).map { String(detail[$0]) } ?? "not JSON"
        }
    }

    /// The text re-indented with two spaces, like Prettier, keeping the keys' order, comments, and every string as written.
    /// Nil when the text isn't JSON, so a file with a typo is never touched.
    public static func pretty(_ text: String) -> String? { reformat(text, pretty: true) }

    /// The text on one line with no spaces between its parts. Line comments become block comments, which can't swallow what follows.
    public static func minified(_ text: String) -> String? { reformat(text, pretty: false) }

    private static func reformat(_ text: String, pretty: Bool) -> String? {
        guard problem(text) == nil else { return nil }
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        var depth = 0
        // A line break and indent owed before whatever comes next, so a comment can still join the line before it.
        var pendingBreak = false
        // The source broke the line since the last thing written.
        var newlineSince = false
        var afterComment = false

        func flush() {
            guard pendingBreak else { return }
            pendingBreak = false
            guard pretty else { return }
            out.append(0x0A)
            out.append(contentsOf: repeatElement(0x20, count: depth * 2))
        }

        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if isSpace(byte) {
                if byte == 0x0A { newlineSince = true }
                i += 1
                continue
            }
            if let end = commentEnd(bytes, at: i) {
                var comment = Array(bytes[i..<end])
                let line = comment[1] == 0x2F
                if line {
                    while let last = comment.last, isSpace(last) { comment.removeLast() }
                }
                if pretty {
                    // A comment on its own line keeps its own line. One after something stays beside it.
                    if newlineSince || out.isEmpty {
                        pendingBreak = !out.isEmpty
                        flush()
                    } else {
                        out.append(0x20)
                    }
                    out.append(contentsOf: comment)
                    if line { pendingBreak = true }
                } else {
                    flush()
                    if line {
                        let body = String(decoding: comment.dropFirst(2), as: UTF8.self).replacingOccurrences(of: "*/", with: "* /")
                        comment = Array("/*\(body) */".utf8)
                    }
                    out.append(contentsOf: comment)
                }
                i = end
                newlineSince = false
                afterComment = true
                continue
            }
            if pretty, afterComment {
                if newlineSince { pendingBreak = true } else if !pendingBreak { out.append(0x20) }
            }
            afterComment = false
            newlineSince = false
            switch byte {
            case 0x22:
                flush()
                var end = i + 1
                var escaped = false
                while end < bytes.count {
                    let next = bytes[end]
                    end += 1
                    if escaped { escaped = false } else if next == 0x5C { escaped = true } else if next == 0x22 { break }
                }
                out.append(contentsOf: bytes[i..<end])
                i = end
                continue
            case 0x7B, 0x5B:
                flush()
                // An empty object or array stays on one line. In ASCII, } and ] sit two after { and [.
                var next = i + 1
                while next < bytes.count, isSpace(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == byte + 2 {
                    out.append(contentsOf: [byte, byte + 2])
                    i = next + 1
                    continue
                }
                out.append(byte)
                depth += 1
                pendingBreak = true
            case 0x7D, 0x5D:
                depth -= 1
                pendingBreak = true
                flush()
                out.append(byte)
            case 0x2C:
                out.append(byte)
                pendingBreak = true
            case 0x3A:
                out.append(contentsOf: pretty ? [0x3A, 0x20] : [0x3A])
            default:
                flush()
                out.append(byte)
            }
            i += 1
        }
        if pretty { out.append(0x0A) }
        return String(decoding: out, as: UTF8.self)
    }

    /// The text as strict JSON for Foundation to check: comments become spaces and trailing commas go, so every position stays put.
    private static func strict(_ bytes: [UInt8]) -> [UInt8] {
        var bytes = bytes
        var i = 0
        var lastComma: Int?
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x22 {
                lastComma = nil
                i += 1
                var escaped = false
                while i < bytes.count {
                    let next = bytes[i]
                    i += 1
                    if escaped { escaped = false } else if next == 0x5C { escaped = true } else if next == 0x22 { break }
                }
                continue
            }
            if let end = commentEnd(bytes, at: i) {
                for j in i..<end where bytes[j] != 0x0A { bytes[j] = 0x20 }
                i = end
                continue
            }
            if byte == 0x7D || byte == 0x5D, let comma = lastComma { bytes[comma] = 0x20 }
            if byte == 0x2C { lastComma = i } else if !isSpace(byte) { lastComma = nil }
            i += 1
        }
        return bytes
    }

    /// Where a comment starting at `i` ends: a line comment before its line break, a block comment after its */.
    private static func commentEnd(_ bytes: [UInt8], at i: Int) -> Int? {
        guard bytes[i] == 0x2F, i + 1 < bytes.count else { return nil }
        if bytes[i + 1] == 0x2F {
            var end = i + 2
            while end < bytes.count, bytes[end] != 0x0A { end += 1 }
            return end
        }
        guard bytes[i + 1] == 0x2A else { return nil }
        var end = i + 2
        while end + 1 < bytes.count, !(bytes[end] == 0x2A && bytes[end + 1] == 0x2F) { end += 1 }
        return min(end + 2, bytes.count)
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
}
