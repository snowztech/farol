import Foundation
import Testing
@testable import FarolCore

@Test func framesAMessageWithItsLength() throws {
    let data = try #require(LSP.frame(["jsonrpc": "2.0", "id": 1]))
    let text = String(decoding: data, as: UTF8.self)
    let body = text.components(separatedBy: "\r\n\r\n")[1]
    #expect(text.hasPrefix("Content-Length: \(body.utf8.count)\r\n\r\n"))
}

@Test func readsMessagesThatArriveInPieces() throws {
    let one = try #require(LSP.frame(["id": 1, "result": NSNull()]))
    let two = try #require(LSP.frame(["method": "window/logMessage", "params": ["message": "é"]]))
    let stream = one + two
    var reader = LSP.Reader()
    // Split inside the second header and inside its body.
    let cut = one.count + 7
    #expect(reader.read(stream.prefix(cut)).map { $0["id"] as? Int } == [1])
    #expect(reader.read(stream.dropFirst(cut).prefix(10)).isEmpty)
    let rest = reader.read(stream.dropFirst(cut + 10))
    #expect(rest.count == 1)
    #expect((rest[0]["params"] as? [String: Any])?["message"] as? String == "é")
}

@Test func readsLocationsLinksAndNothing() {
    let location: [String: Any] = ["uri": "file:///p/a%20b.go", "range": ["start": ["line": 3, "character": 5], "end": ["line": 3, "character": 9]]]
    let link: [String: Any] = [
        "targetUri": "file:///p/c.go",
        "targetRange": ["start": ["line": 1, "character": 0], "end": ["line": 9, "character": 1]],
        "targetSelectionRange": ["start": ["line": 1, "character": 5], "end": ["line": 1, "character": 9]],
    ]
    #expect(LSP.locations(from: location) == [LSP.Location(path: "/p/a b.go", position: .init(line: 3, character: 5))])
    // A link points at the name, not the start of the whole declaration.
    #expect(LSP.locations(from: [link]) == [LSP.Location(path: "/p/c.go", position: .init(line: 1, character: 5))])
    #expect(LSP.locations(from: nil).isEmpty)
    #expect(LSP.locations(from: NSNull()).isEmpty)
}

@Test func countsPositionsInUTF16LikeServers() {
    let text = "let a = 1\nlet 🙂 = b\n"
    #expect(LSP.position(of: 0, in: text) == .init(line: 0, character: 0))
    #expect(LSP.position(of: 10, in: text) == .init(line: 1, character: 0))
    // The emoji is two UTF-16 units, so b is at 9 on its line.
    let b = (text as NSString).range(of: "b").location
    #expect(LSP.position(of: b, in: text) == .init(line: 1, character: 9))
}

@Test func picksTheServerByExtensionAndFindsItOnThePath() throws {
    #expect(LSP.server(for: "/p/main.go")?.name == "gopls")
    #expect(LSP.server(for: "/p/App.tsx")?.name == "typescript-language-server")
    #expect(LSP.server(for: "/p/notes.txt") == nil)
    #expect(LSP.languageID(for: "a.tsx") == "typescriptreact")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let tool = folder + "/gopls"
    FileManager.default.createFile(atPath: tool, contents: Data(), attributes: [.posixPermissions: 0o755])
    #expect(LSP.locate("gopls", in: "/nowhere:\(folder)") == tool)
    #expect(LSP.locate("clangd", in: folder) == nil)
}

@Test func readsAShortVersionFromWhatServersReport() {
    #expect(LSP.version("v0.21.1") == "v0.21.1")
    let gopls = #"{"GoVersion":"go1.25.8","Path":"golang.org/x/tools/gopls","Deps":[{"Key":"GOARM64","Value":"v8.0"}],"Version":"v0.21.1"}"#
    #expect(LSP.version(gopls) == "v0.21.1")
    #expect(LSP.version(String(repeating: "x", count: 40)) == nil)
    #expect(LSP.version(nil) == nil)
}

@Test func namesTheFilesLanguageShortly() {
    #expect(LSP.languageName(for: "/p/main.go") == "Go")
    #expect(LSP.languageName(for: "/p/App.tsx") == "TSX")
    #expect(LSP.languageName(for: "/p/a.hpp") == "C++")
    #expect(LSP.languageName(for: "/p/notes.txt") == nil)
}
