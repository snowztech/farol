import Foundation
import Testing
@testable import FarolCore

private let sample = """
    diff --git a/Sources/app.swift b/Sources/app.swift
    index 1111111..2222222 100644
    --- a/Sources/app.swift
    +++ b/Sources/app.swift
    @@ -10,4 +10,5 @@ struct App {
     let a = 1
    -let b = 2
    +let b = 3
    +let c = 4
     let d = 5
    diff --git a/old name.txt b/new name.txt
    similarity index 90%
    rename from old name.txt
    rename to new name.txt
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    --- a/gone.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -bye
    \\ No newline at end of file
    diff --git a/logo.png b/logo.png
    Binary files a/logo.png and b/logo.png differ

    """

@Test func parsesFilesHunksAndLineNumbers() {
    let files = Diff.parse(sample)
    #expect(files.map(\.path) == ["Sources/app.swift", "new name.txt", "gone.txt", "logo.png"])

    let app = files[0]
    #expect(app.status == .modified)
    #expect((app.added, app.removed) == (2, 1))
    #expect(app.hunks[0].lines.map(\.number) == [10, nil, 11, 12, 13])
    #expect(app.hunks[0].lines.map(\.text) == ["let a = 1", "let b = 2", "let b = 3", "let c = 4", "let d = 5"])

    // The first change removes line 11, so the file opens there.
    #expect(app.firstChange == 11)

    #expect(files[1].status == .renamed)
    #expect(files[1].oldPath == "old name.txt")
    #expect(files[2].status == .deleted)
    #expect(files[2].hunks[0].lines.map(\.kind) == [.removed])
    #expect(files[3].isBinary)
}

private func commit(_ box: Sandbox, _ message: String) throws {
    try Git.run(["add", "-A"], in: box.repo)
    try Git.run(["-c", "user.name=Farol", "-c", "user.email=farol@example.com", "commit", "--quiet", "-m", message], in: box.repo)
}

private func write(_ text: String, _ name: String, in box: Sandbox) throws {
    try text.write(toFile: box.repo + "/" + name, atomically: true, encoding: .utf8)
}

@Test func uncommittedIncludesUntrackedFiles() throws {
    let box = try Sandbox()
    try write("one\ntwo\n", "a.txt", in: box)
    try commit(box, "a")
    try write("one\n2\n", "a.txt", in: box)
    try write("new\nfile\nhere\n", "b.txt", in: box)

    let files = try Diff.files(in: box.repo, .uncommitted)
    #expect(files.map(\.path) == ["a.txt", "b.txt"])
    #expect(files[1].status == .added)
    #expect(files[1].added == 3)
    #expect(try Diff.stat(in: box.repo, .uncommitted) == Diff.Stat(files: 2, added: 4, removed: 1))
}

@Test func branchScopeCoversCommitsSinceTheBase() throws {
    let box = try Sandbox()
    #expect(Diff.baseBranch(in: box.repo) == "main")
    #expect(Diff.defaultScope(in: box.repo) == .uncommitted)

    try Git.run(["checkout", "--quiet", "-b", "feat"], in: box.repo)
    try write("committed\n", "c.txt", in: box)
    try commit(box, "c")
    try write("not yet\n", "d.txt", in: box)

    #expect(Diff.defaultScope(in: box.repo) == .branch(base: "main"))
    #expect(try Diff.files(in: box.repo, .branch(base: "main")).map(\.path) == ["c.txt", "d.txt"])
    #expect(try Diff.files(in: box.repo, .uncommitted).map(\.path) == ["d.txt"])
}

@Test func readsWhatOneCommitChanged() throws {
    let box = try Sandbox()
    try write("one\n", "a.txt", in: box)
    try commit(box, "add a")
    try write("one\ntwo\n", "a.txt", in: box)
    try write("b\n", "b.txt", in: box)
    try commit(box, "change a, add b")
    // Uncommitted work and untracked files don't belong to any commit.
    try write("three\n", "c.txt", in: box)

    let head = try Git.run(["rev-parse", "HEAD"], in: box.repo)
    let files = try Diff.files(in: box.repo, .commit(head))
    #expect(files.map(\.path) == ["a.txt", "b.txt"])
    #expect(files[1].status == .added)
    #expect(try Diff.stat(in: box.repo, .commit(head)) == Diff.Stat(files: 2, added: 2, removed: 0))
    #expect(Diff.Stat(files) == Diff.Stat(files: 2, added: 2, removed: 0))

    // The first commit of the repo, with no parent, shows everything it added.
    let root = try Git.run(["rev-list", "--max-parents=0", "HEAD"], in: box.repo)
    #expect(try Diff.files(in: box.repo, .commit(root)).isEmpty)
    let first = try Git.run(["rev-parse", "HEAD~1"], in: box.repo)
    #expect(try Diff.files(in: box.repo, .commit(first)).map(\.path) == ["a.txt"])
}

@Test func aRequestNeedsAForge() throws {
    let box = try Sandbox()
    #expect(!Diff.Scope.request(1).isYours)
    // No remote, so no forge to ask for the request's changes.
    #expect(throws: (any Error).self) { try Diff.files(in: box.repo, .request(1)) }
}

@Test func findsAnUnchangedLinesOldNumber() {
    let file = Diff.parse(sample)[0]
    // "let a" opens the hunk on both sides. "let d" comes after one removed and two added lines.
    #expect(file.oldLine(forNew: 10) == 10)
    #expect(file.oldLine(forNew: 13) == 12)
    // An added line has no old number, and neither does a line the diff doesn't show.
    #expect(file.oldLine(forNew: 11) == nil)
    #expect(file.oldLine(forNew: 99) == nil)
}

@Test func expandingJoinsUnmodifiedLinesToTheHunkAround() {
    let app = Diff.parse(sample)[0]
    let text = (1...15).map { "line \($0)" }
    #expect(app.gaps == [1..<10])

    let above = app.expanding(5..<10, from: text)
    #expect(above.gaps == [1..<5])
    #expect(above.hunks.count == 1)
    #expect((above.hunks[0].oldStart, above.hunks[0].newStart) == (5, 5))
    #expect(above.hunks[0].lines.prefix(5).map(\.text) == ["line 5", "line 6", "line 7", "line 8", "line 9"])
    #expect(above.hunks[0].lines.prefix(5).map(\.number) == [5, 6, 7, 8, 9])

    // Lines the diff already shows are left alone, which used to build a backwards range and crash.
    #expect(above.expanding(5..<10, from: text) == above)

    // The hunk added a line, so the old file is one line behind after it.
    let below = app.expanding(14..<30, from: text)
    #expect(below.hunks[0].lines.suffix(2).map(\.text) == ["line 14", "line 15"])
    #expect(below.hunks[0].lines.suffix(2).map(\.number) == [14, 15])
}

@Test func expandingKeepsAGapBetweenHunksThatDontTouch() {
    let hunks = [
        Diff.Hunk(oldStart: 2, newStart: 2, lines: [.init(kind: .added, text: "x", number: 2)]),
        Diff.Hunk(oldStart: 9, newStart: 10, lines: [.init(kind: .added, text: "y", number: 10)]),
    ]
    let file = Diff.File(path: "a.txt", hunks: hunks)
    let text = (1...12).map { "line \($0)" }
    #expect(file.gaps == [1..<2, 3..<10])

    let part = file.expanding(3..<6, from: text)
    #expect(part.gaps == [1..<2, 6..<10])
    #expect(part.hunks.count == 2)

    let all = file.expanding(3..<10, from: text)
    #expect(all.gaps == [1..<2])
    #expect(all.hunks.count == 1)
}
