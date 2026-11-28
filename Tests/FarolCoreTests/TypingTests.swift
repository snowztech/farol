import Foundation
import Testing
@testable import FarolCore

/// The text after an edit, with | for the cursor, or [ ] around the selection.
private func run(_ text: String, _ edit: (NSString, NSRange) -> LineEditing.Edit?) -> String? {
    let marked = text as NSString
    let start = marked.range(of: "|").location != NSNotFound ? marked.range(of: "|").location : marked.range(of: "[").location
    let selection: NSRange
    var plain = text
    if marked.range(of: "|").location != NSNotFound {
        plain = text.replacingOccurrences(of: "|", with: "")
        selection = NSRange(location: start, length: 0)
    } else {
        plain = text.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        selection = NSRange(location: start, length: marked.range(of: "]").location - start - 1)
    }
    guard let edit = edit(plain as NSString, selection) else { return nil }
    let after = NSMutableString(string: plain)
    after.replaceCharacters(in: edit.range, with: edit.replacement)
    if edit.selection.length == 0 { after.insert("|", at: edit.selection.location) } else {
        after.insert("]", at: NSMaxRange(edit.selection))
        after.insert("[", at: edit.selection.location)
    }
    return after as String
}

@Test func findsTheFilesIndent() {
    #expect(Typing.indentUnit(of: "a\n  b\n    c\n  d\n") == "  ")
    #expect(Typing.indentUnit(of: "a\n\tb\n\t\tc\n") == "\t")
    #expect(Typing.indentUnit(of: "/**\n * doc\n */\nf {\n    x\n}\n") == "    ")
    #expect(Typing.indentUnit(of: "flat\n", fallback: "\t") == "\t")
}

@Test func indentsAndOutdents() {
    #expect(run("ab|c") { Typing.indent($0, $1, unit: "    ") } == "ab  |c")
    #expect(run("|x") { Typing.indent($0, $1, unit: "\t") } == "\t|x")
    #expect(run("[a\nb]\n") { Typing.indent($0, $1, unit: "  ") } == "[  a\n  b]\n")
    #expect(run("[a\n\nb]") { Typing.indent($0, $1, unit: "  ") } == "[  a\n\n  b]")
    #expect(run("    a|b") { Typing.outdent($0, $1, unit: "    ") } == "a|b")
    #expect(run("  |ab") { Typing.outdent($0, $1, unit: "    ") } == "|ab")
    #expect(run("\tx|") { Typing.outdent($0, $1, unit: "\t") } == "x|")
    #expect(run("a|b") { Typing.outdent($0, $1, unit: "    ") } == nil)
}

@Test func pairsBracketsAndQuotes() {
    #expect(run("f|") { Typing.type("(", $0, $1) } == "f(|)")
    #expect(run("|word") { Typing.type("(", $0, $1) } == nil)
    #expect(run("f(|)") { Typing.type(")", $0, $1) } == "f()|")
    #expect(run("[ab]") { Typing.type("\"", $0, $1) } == "\"[ab]\"")
    #expect(run("x = |") { Typing.type("\"", $0, $1) } == "x = \"|\"")
    #expect(run("don|") { Typing.type("'", $0, $1) } == nil)
    #expect(run("\"a|\"") { Typing.type("\"", $0, $1) } == "\"a\"|")
    #expect(run("a|") { Typing.type("x", $0, $1) } == nil)
}

@Test func deletesPairsAndIndentStops() {
    #expect(run("f(|)") { Typing.deleteBackward($0, $1, unit: "    ") } == "f|")
    #expect(run("        |x") { Typing.deleteBackward($0, $1, unit: "    ") } == "    |x")
    #expect(run("      |x") { Typing.deleteBackward($0, $1, unit: "    ") } == "    |x")
    #expect(run("a |") { Typing.deleteBackward($0, $1, unit: "    ") } == nil)
    #expect(run("\t\t|") { Typing.deleteBackward($0, $1, unit: "\t") } == nil)
}

@Test func newLinesKeepAndAddIndent() {
    #expect(run("  a|") { Typing.newline($0, $1, unit: "  ") } == "  a\n  |")
    #expect(run("  f {|}") { Typing.newline($0, $1, unit: "  ") } == "  f {\n    |\n  }")
    #expect(run("f(|") { Typing.newline($0, $1, unit: "\t") } == "f(\n\t|")
    #expect(run("if x:|") { Typing.newline($0, $1, unit: "    ") } == "if x:\n    |")
    #expect(run("a: b|") { Typing.newline($0, $1, unit: "  ") } == "a: b\n|")
    #expect(run("Note:|") { Typing.newline($0, $1, unit: "  ", colonOpens: false) } == "Note:\n|")
}

@Test func matchesBrackets() {
    let text = "f(a[1], {b})" as NSString
    #expect(Typing.matchingBracket(text, at: 2).map { [$0.0.location, $0.1.location] } == [1, 11])
    #expect(Typing.matchingBracket(text, at: 12).map { [$0.0.location, $0.1.location] } == [11, 1])
    #expect(Typing.matchingBracket(text, at: 4).map { [$0.0.location, $0.1.location] } == [3, 5])
    #expect(Typing.matchingBracket("ab" as NSString, at: 1) == nil)
    #expect(Typing.matchingBracket("(a" as NSString, at: 1) == nil)
}

@Test func measuresIndentLevelsForGuides() {
    let text = "f {\n    a\n\n        b\n    c\n}\n\ng\n" as NSString
    let level = { (line: Int) in
        Typing.indentLevel(text, at: (text as String).components(separatedBy: "\n").prefix(line).map { ($0 as NSString).length + 1 }.reduce(0, +), unit: "    ")
    }
    #expect([0, 1, 2, 3, 4, 5, 6, 7].map(level) == [0, 1, 1, 2, 1, 0, 0, 0])
    #expect(Typing.indentLevel("\t\tx" as NSString, at: 0, unit: "\t") == 2)
    #expect(Typing.indentLevel("  x" as NSString, at: 0, unit: "    ") == 0)
}
