import Foundation
import Testing
@testable import FarolCore

private func folder(_ files: [String: String]) throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("farol-files-\(UUID().uuidString)")
    for (path, text) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return root.path
}

@Test func listsFoldersFirstInFinderOrder() throws {
    let root = try folder(["b.txt": "", "a10.txt": "", "a2.txt": "", "Sources/x.swift": "", ".env": "", ".DS_Store": ""])
    #expect(Files.list(root).map(\.name) == ["Sources", ".env", "a2.txt", "a10.txt", "b.txt"])
    #expect(Files.list(root).first?.isDirectory == true)
}

@Test func marksWhatGitIgnores() throws {
    let root = try folder([".gitignore": "build/\n*.log\n", "build/out.o": "", "app.log": "", "main.swift": ""])
    try Git.run(["init", "--quiet"], in: root)
    let base = URL(fileURLWithPath: root).standardizedFileURL.path
    #expect(Files.ignored(in: root) == ["\(base)/build", "\(base)/app.log"])
}

@Test func readsTextButNotBinaries() throws {
    let root = try folder(["a.swift": "let x = 1\n"])
    #expect(try Files.read(root + "/a.swift") == .text("let x = 1\n"))
    let binary = root + "/a.bin"
    try Data([0x89, 0x50, 0x00, 0x01]).write(to: URL(fileURLWithPath: binary))
    #expect(try Files.read(binary) == .binary)
    let big = root + "/big.txt"
    try Data(repeating: 65, count: Files.sizeLimit + 1).write(to: URL(fileURLWithPath: big))
    #expect(try Files.read(big) == .tooLarge)
}

@Test func listsWhatGitTracksOrWouldAdd() throws {
    let root = try folder([".gitignore": "build/\n", "build/out.o": "", "src/café.swift": "", "main.swift": ""])
    try Git.run(["init", "--quiet"], in: root)
    try Git.run(["add", "main.swift"], in: root)
    #expect(Set(Files.tracked(in: root)) == [".gitignore", "main.swift", "src/café.swift"])
    #expect(Files.tracked(in: try folder(["a.txt": ""])).isEmpty)
}

@Test func searchPutsNameMatchesFirst() {
    let paths = ["Sources/Store/Index.swift", "Sources/Farol/SessionStore.swift", "Tests/StoreTests.swift", "README.md"]
    #expect(Files.search(paths, "store") == ["Tests/StoreTests.swift", "Sources/Farol/SessionStore.swift", "Sources/Store/Index.swift"])
    #expect(Files.search(paths, "farol STORE") == ["Sources/Farol/SessionStore.swift"])
    #expect(Files.search(paths, "store", limit: 1) == ["Tests/StoreTests.swift"])
    #expect(Files.search(paths, " ").isEmpty)
}

@Test func searchPutsNamesThatStartWithTheWordFirst() {
    let paths = [".claude/", "README.md", "site/docs.html", "scripts/dist.sh"]
    #expect(Files.search(paths, "d") == ["site/docs.html", "scripts/dist.sh", ".claude/", "README.md"])
}

@Test func searchableAddsTheFoldersOfACheckout() throws {
    let root = try folder([".gitignore": "build/\n", "build/out.o": "", "src/app/main.swift": "", "README.md": ""])
    try Git.run(["init", "--quiet"], in: root)
    #expect(Files.searchable(in: root) == ["src/", "src/app/", ".gitignore", "README.md", "src/app/main.swift"])
    #expect(Files.search(Files.searchable(in: root), "app") == ["src/app/", "src/app/main.swift"])
}

@Test func searchableWalksAFolderOutsideGit() throws {
    let root = try folder(["a.txt": "", ".env": "", "one/b.txt": "", "one/two/c.txt": "", "one/two/three/d.txt": ""])
    #expect(Files.searchable(in: root) == ["one/", "a.txt", "one/two/", "one/b.txt", "one/two/three/", "one/two/c.txt"])
    #expect(Files.walk(root, limit: 2) == ["one/", "a.txt"])
}

@Test func walkSkipsInstalledDependencies() throws {
    let root = try folder(["index.js": "", "node_modules/left-pad/index.js": "", "src/__pycache__/a.pyc": "", "src/a.py": ""])
    #expect(Files.walk(root) == ["src/", "index.js", "src/a.py"])
}
