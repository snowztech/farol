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

@Test func spellsAPathAsAListingOfItsFolderDoes() throws {
    let root = try folder(["src/a.swift": ""])
    let link = root + "-link"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root)
    // Through a link the rows still come out as the real folder's, and so does the path.
    let listed = Files.list(link + "/src").map(\.path)
    #expect(listed == [Files.realPath(link + "/src/a.swift")])
    #expect(Files.realPath("/does/not/exist") == "/does/not/exist")
}

@Test func listsTheFoldersToOpenToReachAFile() {
    #expect(Files.folders(from: "/p", to: "/p/a.swift") == [])
    #expect(Files.folders(from: "/p", to: "/p/Sources/App/main.swift") == ["/p/Sources", "/p/Sources/App"])
    // Not under the folder, even when the names start alike.
    #expect(Files.folders(from: "/p", to: "/other/a.swift") == nil)
    #expect(Files.folders(from: "/p", to: "/project/a.swift") == nil)
}

@Test func saysWhatsWrongWithANewName() throws {
    let root = try folder(["src/a.swift": ""])
    #expect(Files.problem(creating: "b.swift", in: root) == nil)
    #expect(Files.problem(creating: "api/handler.go", in: root) == nil)
    #expect(Files.problem(creating: "  ", in: root) == "Type a name.")
    #expect(Files.problem(creating: "src", in: root) == "src already exists here.")
    #expect(Files.problem(creating: "src/a.swift", in: root) == "src/a.swift already exists here.")
    #expect(Files.problem(creating: "../out.txt", in: root) == "Use a name inside this folder.")
    #expect(Files.problem(creating: "/etc/x", in: root) == "Use a name inside this folder.")
    #expect(Files.problem(creating: "new/", in: root) == "A name can't end with a slash.")
}

@Test func createsFilesAndFoldersWithTheFoldersOnTheWay() throws {
    let root = try folder(["src/a.swift": ""])
    let file = try Files.create("api/v1/handler.go", in: root, directory: false)
    #expect(FileManager.default.fileExists(atPath: file))
    #expect(file == root + "/api/v1/handler.go")
    var isDirectory: ObjCBool = false
    let made = try Files.create("docs/notes", in: root, directory: true)
    #expect(FileManager.default.fileExists(atPath: made, isDirectory: &isDirectory) && isDirectory.boolValue)
    // Never replaces what's there.
    #expect(throws: (any Error).self) { try Files.create("src/a.swift", in: root, directory: false) }
}
