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
