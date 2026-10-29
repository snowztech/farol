import Foundation
import Testing
@testable import FarolCore

private let first = String(repeating: "a", count: 40)
private let second = String(repeating: "b", count: 40)

private let porcelain = """
    \(first) 1 1 2
    author Ada
    author-mail <ada@example.com>
    author-time 1700000000
    author-tz +0000
    summary Add the file
    filename notes.txt
    \tone
    \(first) 2 2
    \ttwo
    \(second) 3 3 1
    author Grace
    author-time 1700086400
    summary Fix line three
    previous \(first) notes.txt
    filename notes.txt
    \tthree
    \(String(repeating: "0", count: 40)) 4 4 1
    author Not Committed Yet
    author-time 1700172800
    summary Version of notes.txt from notes.txt
    filename notes.txt
    \tfour

    """

@Test func blameKeepsOneEntryPerLineAndReusesACommitsDetails() {
    let lines = Blame.parse(porcelain)
    #expect(lines.count == 4)
    #expect(lines.map(\.hash) == [first, first, second, String(repeating: "0", count: 40)])
    #expect(lines[1].author == "Ada")
    #expect(lines[1].summary == "Add the file")
    #expect(lines[2].author == "Grace")
    #expect(lines[0].date == Date(timeIntervalSince1970: 1_700_000_000))
}

@Test func blameTellsCommittedLinesFromOnesNotCommittedYet() {
    let lines = Blame.parse(porcelain)
    #expect(lines[0].isCommitted)
    #expect(!lines[3].isCommitted)
    #expect(lines[0].shortHash == "aaaaaaa")
}
