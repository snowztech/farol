import Foundation
import Testing
@testable import FarolCore

private func file(_ body: String, start: Int = 10) -> Diff.File {
    Diff.parse("""
    diff --git a/app.swift b/app.swift
    --- a/app.swift
    +++ b/app.swift
    @@ -\(start),4 +\(start),5 @@
    \(body)
    """)[0]
}

private let before = file(" let a = 1\n-let b = 2\n+let b = 3\n+let c = 4\n let d = 5")

@Test func quotesTheLinesANoteIsOn() {
    #expect(ReviewNotes.quote(in: before, line: 10, end: 12, old: false) == ["let a = 1", "let b = 2", "let b = 3", "let c = 4"])
    #expect(ReviewNotes.quote(in: before, line: 11, end: 11, old: true) == ["let b = 2"])
    #expect(ReviewNotes.quote(in: before, line: 40, end: 40, old: false) == nil)
}

/// Five lines added above it move the note's line from 12 to 17, and it follows.
@Test func aNoteFollowsItsLineWhenTheAgentEditsAboveIt() {
    let note = ReviewNote(path: "app.swift", line: 12, end: 12, old: false, quote: ["let c = 4"], text: "Name it count")
    let after = file(" let a = 1\n-let b = 2\n+let b = 3\n+let c = 4\n let d = 5", start: 15)
    let moved = ReviewNotes.anchor(note, in: [after])
    #expect(moved.line == 17 && moved.end == 17 && !moved.lost)
}

@Test func aNoteIsLostOnceItsLinesAreGone() {
    let note = ReviewNote(path: "app.swift", line: 12, end: 12, old: false, quote: ["let c = 4"], text: "Name it count")
    let fixed = file(" let a = 1\n-let b = 2\n+let count = 4\n let d = 5")
    #expect(ReviewNotes.anchor(note, in: [fixed]).lost)
    #expect(ReviewNotes.anchor(note, in: []).lost)
}

@Test func writesOneNumberedPrompt() {
    let items = [
        ReviewNotes.Item(path: "app.swift", line: 12, end: 12, old: false, quote: ["", "let c = 4", " "], text: "Name it count"),
        ReviewNotes.Item(path: "README.md", line: 18, end: 19, old: true, quote: ["Old", "lines"], text: "Keep these\nbut shorter",
                         author: "alice"),
    ]
    #expect(ReviewNotes.prompt(items, also: "run the tests") == """
    \(ReviewNotes.yourNotes)

    1. app.swift:12
       > let c = 4
       Name it count

    2. README.md, removed lines 18-19
       > Old
       > lines
       alice: Keep these
       but shorter

    Also: run the tests
    """)
}
