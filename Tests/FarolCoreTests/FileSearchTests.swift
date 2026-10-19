import Foundation
import Testing
@testable import FarolCore

private func folder(_ files: [String: String]) throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("farol-search-\(UUID().uuidString)").path
    for (path, text) in files {
        let file = root + "/" + path
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }
    return root
}

@Test func findsEachLineWithTheTextIgnoringCase() throws {
    let root = try folder(["a.txt": "one\n    Hello there\nhello again\n", "sub/b.txt": "nothing\nsay HELLO\n"])
    let matches = FileSearch.search("hello", in: root).sorted { ($0.path, $0.line) < ($1.path, $1.line) }
    #expect(matches == [
        FileSearch.Match(path: "a.txt", line: 2, text: "Hello there"),
        FileSearch.Match(path: "a.txt", line: 3, text: "hello again"),
        FileSearch.Match(path: "sub/b.txt", line: 2, text: "say HELLO"),
    ])
}

@Test func aCheckoutSkipsWhatGitIgnoresAndSearchesBelowTheFolder() throws {
    let root = try folder([".gitignore": "build/\n", "src/app.swift": "let token = 1\n", "build/out.swift": "let token = 2\n", "top.swift": "token\n"])
    try Git.run(["init", "--quiet"], in: root)
    #expect(FileSearch.search("token", in: root).map(\.path).sorted() == ["src/app.swift", "top.swift"])
    // From a subfolder, only what is under it, with paths from there.
    #expect(FileSearch.search("token", in: root + "/src") == [FileSearch.Match(path: "app.swift", line: 1, text: "let token = 1")])
}

@Test func nothingTypedFindsNothing() throws {
    let root = try folder(["a.txt": "anything"])
    #expect(FileSearch.search("  ", in: root).isEmpty)
    #expect(FileSearch.search("absent", in: root).isEmpty)
}

@Test func stopsAtTheLimit() throws {
    let root = try folder(["a.txt": Array(repeating: "match", count: 10).joined(separator: "\n")])
    #expect(FileSearch.search("match", in: root, limit: 3).count == 3)
}

@Test func caseAndWholeWordNarrowTheSearch() throws {
    let root = try folder(["a.txt": "Token\ntoken\ntokens\nmy_token\n"])
    for checkout in [false, true] {
        if checkout { try Git.run(["init", "--quiet"], in: root) }
        #expect(FileSearch.search("token", in: root).map(\.line) == [1, 2, 3, 4])
        #expect(FileSearch.search("token", in: root, options: .init(caseSensitive: true)).map(\.line) == [2, 3, 4])
        #expect(FileSearch.search("token", in: root, options: .init(wholeWord: true)).map(\.line) == [1, 2])
        #expect(FileSearch.search("Token", in: root, options: .init(caseSensitive: true, wholeWord: true)).map(\.line) == [1])
    }
}

@Test func rangesMarkWhatTheSearchFound() {
    let line = "id width id_x (id)"
    let words = FileSearch.ranges(of: "id", in: line, options: .init(wholeWord: true)).map { line.distance(from: line.startIndex, to: $0.lowerBound) }
    #expect(words == [0, 15])
    #expect(FileSearch.ranges(of: "ID", in: line, options: .init(caseSensitive: true)).isEmpty)
    #expect(FileSearch.ranges(of: "ID", in: line, options: .init()).count == 4)
}

@Test func aRegularExpressionFindsWhatItDescribes() throws {
    let root = try folder(["a.swift": "let x = 1\nvar count = 42\nfunc go() {}\n"])
    for checkout in [false, true] {
        if checkout { try Git.run(["init", "--quiet"], in: root) }
        #expect(FileSearch.search("(let|var) [a-z]+ = [0-9]+", in: root, options: .init(regex: true)).map(\.line) == [1, 2])
        #expect(FileSearch.search("^func", in: root, options: .init(regex: true)).map(\.line) == [3])
        // Without the option, the same text is looked for as it is.
        #expect(FileSearch.search("^func", in: root).isEmpty)
    }
}

@Test func aBrokenExpressionIsInvalidAndFindsNothing() throws {
    #expect(!FileSearch.isValid("(unclosed", options: .init(regex: true)))
    #expect(FileSearch.isValid("(unclosed", options: .init()))
    let line = "a1 b22"
    #expect(FileSearch.ranges(of: "[0-9]+", in: line, options: .init(regex: true)).map { String(line[$0]) } == ["1", "22"])
}

@Test func aCancelledSearchFindsNothing() throws {
    let root = try folder(["a.txt": "match\n"])
    let job = FileSearch.Job()
    job.cancel()
    #expect(FileSearch.search("match", in: root, job: job).isEmpty)
    try Git.run(["init", "--quiet"], in: root)
    #expect(FileSearch.search("match", in: root, job: job).isEmpty)
}

@Test func filesGlobsKeepAndLeaveOutFiles() throws {
    let root = try folder(["src/app.swift": "needle\n", "src/AppTests.swift": "needle\n", "README.md": "needle\n"])
    let options = FileSearch.Options(files: FileSearch.Options.files(from: "*.swift, !*Tests*"))
    for checkout in [false, true] {
        if checkout { try Git.run(["init", "--quiet"], in: root) }
        #expect(FileSearch.search("needle", in: root, options: options).map(\.path) == ["src/app.swift"])
        #expect(FileSearch.search("needle", in: root, options: .init(files: ["!*.md"])).map(\.path).sorted() == ["src/AppTests.swift", "src/app.swift"])
    }
}
