import Foundation
import Testing
@testable import FarolCore

@Test func lineStartsFollowEditsLikeAFullScan() {
    var generator = SystemRandomNumberGenerator()
    let pieces = ["a", "bc", "\n", "\r", "\r\n", "\n\n", "é", "😀", ""]
    for _ in 0..<200 {
        let text = NSMutableString(string: (0..<20).map { _ in pieces.randomElement(using: &generator)! }.joined())
        var lines = LineStarts(text)
        for _ in 0..<30 {
            let location = Int.random(in: 0...text.length, using: &generator)
            let length = Int.random(in: 0...min(4, text.length - location), using: &generator)
            let insert = (0..<Int.random(in: 0...3, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
            // Never split a surrogate pair, which a text view doesn't either.
            let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: location, length: length))
            text.replaceCharacters(in: range, with: insert)
            let delta = (insert as NSString).length - range.length
            lines.edit(NSRange(location: range.location, length: (insert as NSString).length), changeInLength: delta, in: text)
            #expect(lines == LineStarts(text), "after replacing \(range) with \(insert.debugDescription) in \(String(text).debugDescription)")
            if lines != LineStarts(text) { return }
        }
    }
}
