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
    #expect(lines[1].email == "ada@example.com")
}

@Test func blameTellsCommittedLinesFromOnesNotCommittedYet() {
    let lines = Blame.parse(porcelain)
    #expect(lines[0].isCommitted)
    #expect(!lines[3].isCommitted)
    #expect(lines[0].shortHash == "aaaaaaa")
}

private func commit(_ text: String, as author: String, _ message: String, in box: Sandbox) throws {
    try text.write(toFile: box.repo + "/notes.txt", atomically: true, encoding: .utf8)
    try Git.run(["add", "notes.txt"], in: box.repo)
    try Git.run(["-c", "user.name=\(author)", "-c", "user.email=a@example.com", "-c", "core.autocrlf=false", "commit", "--quiet", "-m", message], in: box.repo)
}

@Test func blameKeepsEachLinesCommitInAFileWithWindowsLineEndings() throws {
    let box = try Sandbox()
    try commit("one\r\ntwo\r\n", as: "Ada", "first", in: box)
    try commit("one\r\ntwo\r\nthree\r\nfour\r\n", as: "Grace", "second", in: box)

    let whole = try Git.run(["blame", "--porcelain", "--", "notes.txt"], in: box.repo, trimming: false)
    #expect(Blame.parse(whole).map(\.summary) == ["first", "first", "second", "second"])
    #expect(Blame.parse(whole).map(\.author) == ["Ada", "Ada", "Grace", "Grace"])
    #expect(Blame.parse(whole)[0].hash != Blame.parse(whole)[2].hash)
}

@Test func blameReadsEveryLineOfTheSavedFile() throws {
    let box = try Sandbox()
    try commit("one\ntwo\n", as: "Ada", "first", in: box)
    try commit("one\ntwo\nthree\n", as: "Grace", "second", in: box)
    let path = box.repo + "/notes.txt"

    #expect(Blame.lines(of: path)?.map(\.author) == ["Ada", "Ada", "Grace"])

    try "one\nTWO\nthree\n".write(toFile: path, atomically: true, encoding: .utf8)
    #expect(Blame.lines(of: path)?.map(\.isCommitted) == [true, false, true])

    try "new\n".write(toFile: box.repo + "/untracked.txt", atomically: true, encoding: .utf8)
    #expect(Blame.lines(of: box.repo + "/untracked.txt") == nil)
}

@Test func blameAgesAreShort() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let ago = { (seconds: Double) in Blame.age(of: now.addingTimeInterval(-seconds), now: now) }
    let day = 86_400.0
    #expect(ago(10) == "now")
    #expect(ago(45 * 60) == "45m")
    #expect(ago(4 * 3_600) == "4h")
    #expect(ago(3 * day) == "3d")
    #expect(ago(14 * day) == "2w")
    #expect(ago(60 * day) == "2mo")
    #expect(ago(800 * day) == "2y")
}
