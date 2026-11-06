import Foundation

/// The pure half of language server support: which servers Farol knows, how messages travel, and the shape of their answers.
/// The app runs the processes. Off unless turned on in Settings, so none of this costs anything otherwise.
public enum LSP {
    /// A server Farol can start for some files.
    public struct Server: Equatable, Sendable {
        /// What Settings and the file pane call it.
        public let name: String
        /// The languages it serves, as Settings lists them.
        public let language: String
        public let command: String
        public let arguments: [String]
        public let extensions: Set<String>
        /// How to get it, for Settings to show when it isn't on your PATH.
        public let install: String
        /// Arguments it answers and exits on, so a stub that only forwards, like rustup's before the component is added, isn't taken for it.
        /// Nil for one that answers nothing without a client.
        public let check: [String]?
    }

    /// The servers people use for each language, the same ones other editors start.
    public static let servers: [Server] = [
        Server(name: "gopls", language: "Go", command: "gopls", arguments: [], extensions: ["go"],
               install: "go install golang.org/x/tools/gopls@latest", check: ["version"]),
        Server(name: "typescript-language-server", language: "TypeScript and JavaScript", command: "typescript-language-server", arguments: ["--stdio"],
               extensions: ["ts", "tsx", "js", "jsx", "mjs", "cjs"], install: "npm install -g typescript-language-server typescript", check: ["--version"]),
        Server(name: "pyright", language: "Python", command: "pyright-langserver", arguments: ["--stdio"], extensions: ["py"],
               install: "npm install -g pyright", check: nil),
        Server(name: "rust-analyzer", language: "Rust", command: "rust-analyzer", arguments: [], extensions: ["rs"],
               install: "rustup component add rust-analyzer", check: ["--version"]),
        Server(name: "sourcekit-lsp", language: "Swift", command: "sourcekit-lsp", arguments: [], extensions: ["swift"],
               install: "xcode-select --install", check: ["--help"]),
        Server(name: "clangd", language: "C, C++ and Objective-C", command: "clangd", arguments: [], extensions: ["c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm"],
               install: "xcode-select --install", check: ["--version"]),
    ]

    public static func server(for path: String) -> Server? {
        let ext = (path as NSString).pathExtension.lowercased()
        return servers.first { $0.extensions.contains(ext) }
    }

    /// The file's language as people call it, short enough for the status bar: "Go", "TSX", "C++".
    public static func languageName(for path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "go": "Go"
        case "ts": "TypeScript"
        case "tsx": "TSX"
        case "js", "mjs", "cjs": "JavaScript"
        case "jsx": "JSX"
        case "py": "Python"
        case "rs": "Rust"
        case "swift": "Swift"
        case "c", "h": "C"
        case "cc", "cpp", "cxx", "hpp": "C++"
        case "m": "Objective-C"
        case "mm": "Objective-C++"
        default: nil
        }
    }

    /// The name a server knows a file's language by.
    public static func languageID(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "ts": "typescript"
        case "tsx": "typescriptreact"
        case "js", "mjs", "cjs": "javascript"
        case "jsx": "javascriptreact"
        case "py": "python"
        case "rs": "rust"
        case "cc", "cpp", "cxx", "hpp": "cpp"
        case "h": "c"
        case "m": "objective-c"
        case "mm": "objective-cpp"
        case let other: other
        }
    }

    /// Your shell's PATH, where servers are looked for, as a terminal would. Starts a shell the first time, so not on the main thread.
    public static var shellPath: String { Git.shellPath }

    /// The shell's PATH with the folders installers write servers to, which a shell often lacks.
    /// `go install` puts gopls in GOBIN or in each GOPATH's bin, and Go's docs leave adding that to your PATH to you.
    /// Starts a shell the first time, so not on the main thread.
    public static var searchPath: String { searchPath(shell: shellPath) }

    static func searchPath(shell: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: String = NSHomeDirectory()) -> String {
        let gopath = (environment["GOPATH"] ?? "").split(separator: ":").map { String($0) + "/bin" }
        let extra = [environment["GOBIN"] ?? ""] + gopath + [home + "/go/bin", home + "/.cargo/bin", home + "/.local/bin"]
        var folders = shell.split(separator: ":").map(String.init)
        for folder in extra where !folder.isEmpty && !folders.contains(folder) { folders.append(folder) }
        return folders.joined(separator: ":")
    }

    /// Where `command` is on `searchPath`, a PATH value, or nil when it isn't installed.
    public static func locate(_ command: String, in searchPath: String) -> String? {
        candidates(command, in: searchPath).first
    }

    /// The first of the server's executables on `searchPath` that runs, passing over stubs that fail its check.
    /// Starts each one it tries, so not on the main thread.
    public static func find(_ server: Server, in searchPath: String) -> String? {
        candidates(server.command, in: searchPath).first { executable in
            server.check.map { runs(executable, $0, path: searchPath) } ?? true
        }
    }

    private static func candidates(_ command: String, in searchPath: String) -> [String] {
        searchPath.split(separator: ":")
            .map { ($0 as NSString).appendingPathComponent(command) }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether `executable` exits cleanly on `arguments`. One still going after a few seconds counts, since a stub fails at once.
    static func runs(_ executable: String, _ arguments: [String], path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return false }
        guard done.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return true
        }
        return process.terminationStatus == 0
    }

    /// The short version a server reports, like "v0.21.1". gopls sends a JSON object with its build in it, whose "Version" is the one.
    /// Anything still long is no version a person reads, so it's left out.
    public static func version(_ reported: String?) -> String? {
        guard var version = reported?.trimmingCharacters(in: .whitespaces), !version.isEmpty else { return nil }
        if version.hasPrefix("{"), let data = version.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            version = (object["Version"] ?? object["version"]) as? String ?? ""
        }
        return version.isEmpty || version.count > 24 ? nil : version
    }

    // MARK: Messages

    /// A message as it goes over the pipe: a header with its length, then the JSON.
    public static func frame(_ message: [String: Any]) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    /// Collects what the server writes, which arrives in pieces of any size, and hands back whole messages.
    public struct Reader {
        private var buffer = Data()
        private static let separator = Data("\r\n\r\n".utf8)

        public init() {}

        public mutating func read(_ data: Data) -> [[String: Any]] {
            buffer.append(data)
            var messages: [[String: Any]] = []
            while let end = buffer.range(of: Self.separator) {
                let header = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                guard let length = header.split(separator: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap({ Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) })
                else {
                    // A header without a length can't be read past, so it is dropped.
                    buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                    continue
                }
                guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { break }
                let body = buffer[end.upperBound..<buffer.index(end.upperBound, offsetBy: length)]
                if let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { messages.append(message) }
                buffer.removeSubrange(buffer.startIndex..<buffer.index(end.upperBound, offsetBy: length))
            }
            return messages
        }
    }

    // MARK: Places

    /// A place in a file as servers count it: lines and UTF-16 units from 0, which is what NSString counts too.
    public struct Position: Equatable, Hashable, Sendable {
        public let line: Int
        public let character: Int

        public init(line: Int, character: Int) {
            self.line = line
            self.character = character
        }

        var json: [String: Any] { ["line": line, "character": character] }
    }

    public struct Location: Equatable, Hashable, Sendable {
        public let path: String
        public let position: Position
    }

    public static func position(of index: Int, in text: String) -> Position {
        let string = text as NSString
        let end = min(index, string.length)
        var (line, start, searched) = (0, 0, 0)
        while searched < end {
            let found = string.range(of: "\n", range: NSRange(location: searched, length: end - searched))
            guard found.location != NSNotFound else { break }
            line += 1
            start = NSMaxRange(found)
            searched = start
        }
        return Position(line: line, character: end - start)
    }

    public static func uri(for path: String) -> String { URL(fileURLWithPath: path).absoluteString }

    public static func path(fromURI uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }

    /// What a definition or references request answered: one place, a list of them, or links that point at them.
    public static func locations(from result: Any?) -> [Location] {
        let items = (result as? [[String: Any]]) ?? (result as? [String: Any]).map { [$0] } ?? []
        return items.compactMap { item in
            // A link names where the name itself is, inside the whole declaration.
            let uri = item["uri"] ?? item["targetUri"]
            let range = item["range"] ?? item["targetSelectionRange"]
            guard let uri = uri as? String, let path = path(fromURI: uri),
                  let start = (range as? [String: Any])?["start"] as? [String: Any],
                  let line = start["line"] as? Int, let character = start["character"] as? Int else { return nil }
            return Location(path: path, position: Position(line: line, character: character))
        }
    }

    static func textDocument(_ path: String) -> [String: Any] { ["uri": uri(for: path)] }

    /// The parameters of a request about a place in a file, like a definition.
    public static func place(_ path: String, _ position: Position) -> [String: Any] {
        ["textDocument": textDocument(path), "position": position.json]
    }
}
