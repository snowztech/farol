import Foundation
import Testing
@testable import FarolCore

private func match(_ path: String, _ row: Int, _ text: String) -> DiffSearch.Match {
    DiffSearch.Match(path: path, row: row, text: text, range: NSRange(location: 0, length: 3))
}

@Test func searchFindsEveryMatchAndStopsAtTheLimit() {
    let files: [(path: String, lines: [(row: Int, text: String)])] = [
        ("a.txt", [(0, "foo foo"), (2, "bar")]),
        ("b.txt", [(1, "foo")]),
    ]
    let found = DiffSearch.matches(in: files, query: "foo", options: .init(), limit: 10)
    #expect(found.map(\.path) == ["a.txt", "a.txt", "b.txt"])
    #expect(found.map(\.row) == [0, 0, 1])
    #expect(found[1].range == NSRange(location: 4, length: 3))
    #expect(DiffSearch.matches(in: files, query: "foo", options: .init(), limit: 2).count == 2)
}

@Test func aMatchIsFollowedWhenEditsAboveMoveItsRow() {
    let before = match("a.txt", 5, "foo two")
    let found = [match("a.txt", 2, "foo one"), match("a.txt", 9, "foo two"), match("a.txt", 40, "foo two"), match("b.txt", 5, "foo two")]
    #expect(DiffSearch.follow(before, in: found) == 1)
}

@Test func aMatchWhoseLineIsGoneFallsBackToTheClosestInItsFile() {
    let before = match("a.txt", 5, "foo two")
    let found = [match("a.txt", 1, "foo one"), match("a.txt", 7, "foo three"), match("b.txt", 5, "foo four")]
    #expect(DiffSearch.follow(before, in: found) == 1)
    #expect(DiffSearch.follow(before, in: [match("b.txt", 5, "foo four")]) == nil)
}
