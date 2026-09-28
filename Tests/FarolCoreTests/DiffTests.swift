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
