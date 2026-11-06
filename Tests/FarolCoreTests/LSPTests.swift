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

@Test func searchesWhereGoInstallsItsToolsAndOtherInstallersDo() {
    // gopls from `go install` lands in GOBIN or a GOPATH's bin, which a shell's PATH does not have by default.
    #expect(LSP.searchPath(shell: "/usr/bin:/bin", environment: ["GOBIN": "/g/bin", "GOPATH": "/a:/b"], home: "/h")
        == "/usr/bin:/bin:/g/bin:/a/bin:/b/bin:/h/go/bin:/h/.cargo/bin:/h/.local/bin")
    // Nothing is added twice, and an app opened from the Dock has none of those variables.
    #expect(LSP.searchPath(shell: "/h/go/bin:/usr/bin", environment: [:], home: "/h") == "/h/go/bin:/usr/bin:/h/.cargo/bin:/h/.local/bin")
}

@Test func passesOverAStubThatFailsTheServersCheck() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let (stub, real) = (root + "/stub", root + "/real")
    for (folder, status) in [(stub, 1), (real, 0)] {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder + "/rust-analyzer", contents: Data("#!/bin/sh\nexit \(status)\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
    }
    let server = try #require(LSP.server(for: "/p/main.rs"))
    // rustup puts a rust-analyzer in ~/.cargo/bin that fails until the component is added.
    #expect(LSP.find(server, in: "\(stub):\(real)") == real + "/rust-analyzer")
    #expect(LSP.find(server, in: stub) == nil)
}

@Test func installReturnsWhatAFailedCommandPrinted() {
    func server(_ install: String) -> LSP.Server {
        LSP.Server(name: "x", language: "X", command: "x", arguments: [], extensions: [], install: install, check: nil)
    }
    #expect(LSP.install(server("true")) == nil)
    #expect(LSP.install(server("echo 'npm ERR! EACCES' >&2 && exit 243")) == "npm ERR! EACCES")
}

@Test func vueHasItsOwnServerEntryAndTheOthersKeepTheirIds() {
    let vue = LSP.server(for: "/p/Cart.vue")
    #expect(vue?.id == "vue")
    #expect(vue?.command == "typescript-language-server")
    #expect(LSP.server(for: "/p/App.tsx")?.id == "typescript-language-server")
    #expect(LSP.languageName(for: "Cart.vue") == "Vue")
    #expect(LSP.languageID(for: "Cart.vue") == "vue")
    // A saved choice is named by the id, which stays the command for every server but the bundle.
    #expect(Set(LSP.servers.map(\.id)).count == LSP.servers.count)
    #expect(LSP.servers.filter { $0.bundle == nil }.allSatisfy { $0.id == $0.command })
}

@Test func startsABundleWithItsPluginOnceItIsInstalled() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let vue = try #require(LSP.server(for: "/p/Cart.vue"))
    // Nothing to load before the install, and the server isn't found, even with the plain one on the PATH, which doesn't know Vue.
    let plain = home + "/plain"
    try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: plain + "/typescript-language-server", contents: Data("#!/bin/sh\necho 6.0.3\n".utf8),
                                   attributes: [.posixPermissions: 0o755])
    #expect(LSP.initializationOptions(for: vue, home: home) == nil)
    #expect(LSP.find(vue, in: plain, home: home) == nil)
    #expect(LSP.find(try #require(LSP.server(for: "/p/App.ts")), in: plain, home: home) == plain + "/typescript-language-server")

    let root = home + "/.farol/language-servers/vue/node_modules"
    try FileManager.default.createDirectory(atPath: root + "/.bin", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: root + "/@vue/typescript-plugin", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: root + "/@vue/typescript-plugin/package.json", contents: Data("{}".utf8))
    let tool = root + "/.bin/typescript-language-server"
    FileManager.default.createFile(atPath: tool, contents: Data("#!/bin/sh\necho 6.0.3\n".utf8), attributes: [.posixPermissions: 0o755])

    #expect(LSP.find(vue, in: plain, home: home) == tool)
    let options = try #require(LSP.initializationOptions(for: vue, home: home))
    #expect((options["tsserver"] as? [String: String])?["path"] == root + "/typescript/lib")
    let plugin = (options["plugins"] as? [[String: Any]])?.first
    #expect(plugin?["name"] as? String == "@vue/typescript-plugin")
    #expect(plugin?["location"] as? String == root + "/@vue/typescript-plugin")
    #expect(plugin?["languages"] as? [String] == ["vue"])
    // A server without a bundle is told nothing.
    #expect(LSP.initializationOptions(for: try #require(LSP.server(for: "/p/main.go")), home: home) == nil)
}
