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
