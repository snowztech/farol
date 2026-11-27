import Foundation
import Testing
@testable import FarolCore

private func marks(_ old: String, _ new: String) -> [String] {
    LineChanges.marks(from: old, to: new).map { "\($0.line):\($0.kind)" }
}

@Test func marksAddedModifiedAndDeletedLines() {
    #expect(marks("a\nb\nc\n", "a\nb\nc\n") == [])
    #expect(marks("a\nc\n", "a\nb\nc\n") == ["1:added"])
    #expect(marks("a\nb\nc\n", "a\nB\nc\n") == ["1:modified"])
    #expect(marks("a\nb\nc\n", "a\nc\n") == ["1:deleted"])
    // Removing the last lines marks one past the end.
    #expect(marks("a\nb\nc\n", "a\n") == ["1:deleted"])
    // Two removed and three added in one place: all three are modified.
    #expect(marks("a\nx\ny\nz\n", "a\n1\n2\n3\nz\n") == ["1:modified", "2:modified", "3:modified"])
}

@Test func marksEveryLineOfANewFile() {
    #expect(marks("", "a\nb") == ["0:added", "1:added"])
    #expect(marks("a\n", "") == ["0:deleted"])
}

/// Committed files compare with HEAD, new ones with nothing, and ignored ones not at all.
@Test func readsTheCommittedVersion() throws {
    let box = try Sandbox()
    let file = box.repo + "/a.txt"
    try "one\ntwo\n".write(toFile: file, atomically: true, encoding: .utf8)
    try "secret\n".write(toFile: box.repo + "/.gitignore", atomically: true, encoding: .utf8)
    #expect(LineChanges.base(of: file) == "")
    try Git.run(["add", "a.txt", ".gitignore"], in: box.repo)
    try Git.run(["-c", "user.name=Farol", "-c", "user.email=farol@example.com", "commit", "--quiet", "-m", "a"], in: box.repo)
    try "one\n2\n".write(toFile: file, atomically: true, encoding: .utf8)
    #expect(LineChanges.base(of: file) == "one\ntwo\n")
    try "x".write(toFile: box.repo + "/secret", atomically: true, encoding: .utf8)
    #expect(LineChanges.base(of: box.repo + "/secret") == nil)
}
