import AppKit
import FarolCore

/// One running language server for one checkout: a process Farol talks to over its stdin and stdout.
/// Everything here lives on the main thread. Only writing to the pipe happens on a queue, so a big file never holds up typing.
@MainActor
final class LanguageServer {
    enum State: Equatable {
        case starting, running, stopped
        case failed(String)
    }

    let server: LSP.Server
    let root: String
    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?() } }
    }
    var onStateChange: (() -> Void)?
    /// When it last answered something for you, so an idle one can be stopped.
    private(set) var lastUsed = Date()
    /// What the server says it is, like gopls's "v0.21.1", once it has started.
    private(set) var version: String?

    /// How much memory it holds right now, read when asked, since it is only shown in its menu.
    var memory: UInt64? {
        guard let pid = process?.processIdentifier else { return nil }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info.pti_resident_size
    }

    private var process: Process?
    private var input: FileHandle?
    private let writes = DispatchQueue(label: "farol.language-server.writes")
    private var reader = LSP.Reader()
    private var nextID = 1
    private var pending: [Int: (Any?) -> Void] = [:]
    /// Requests asked for while it starts, sent once it is ready.
    private var queued: [() -> Void] = []
    /// What the server has been sent of each open file: its version and text, so unchanged text isn't sent again.
    private var documents: [String: (version: Int, text: String)] = [:]
    /// The last lines it wrote to stderr or logged, for Open Logs. Kept short, since a chatty server would grow it without end.
    private(set) var log: [String] = []
    private static let logLimit = 2000
    /// A server that never answers would leave a ⌘-click waiting, so a request gives up after this.
    /// Long enough for the first answer, which waits for the server to load the project: gopls took 12 seconds on a small one.
    private static let timeout: TimeInterval = 30

    init(server: LSP.Server, root: String) {
        self.server = server
        self.root = root
    }

    func start(executable: String) {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = server.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        // Your shell's PATH, since servers start the tools they wrap, like go or node.
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": LSP.shellPath]) { $1 }
        let (stdin, stdout, stderr) = (Pipe(), Pipe(), Pipe())
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Empty data means the pipe closed. The handler would otherwise be called again and again, spinning a core.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return handle.readabilityHandler = nil }
            DispatchQueue.main.async { self?.received(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return handle.readabilityHandler = nil }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.append(text) }
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async { self?.ended(status: status) }
        }
        do {
            try process.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        state = .starting
        initialize()
    }

    /// Asks it to shut down, as the protocol says, and ends the process if it doesn't in a moment.
    func stop() {
        guard let process else { return }
        pending.values.forEach { $0(nil) }
        pending = [:]
        queued = []
        documents = [:]
        if state == .running { send(["jsonrpc": "2.0", "id": takeID(), "method": "shutdown"]) }
        send(["jsonrpc": "2.0", "method": "exit"])
        state = .stopped
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if process.isRunning { process.terminate() } }
        self.process = nil
        input = nil
    }

    /// Asks the server something. `done` gets its result, or nil when it fails, gives up or isn't running.
    func request(_ method: String, _ params: [String: Any], then done: @escaping (Any?) -> Void) {
        lastUsed = Date()
        switch state {
        case .starting: queued.append { [weak self] in self?.request(method, params, then: done) }
        case .running:
            let id = takeID()
            pending[id] = done
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                self?.pending.removeValue(forKey: id)?(nil)
            }
        case .stopped, .failed: done(nil)
        }
    }

    /// Tells the server what the file holds now, opening it the first time. The whole text, which servers all accept.
    func sync(_ path: String, text: String) {
        guard state == .running else {
            if state == .starting { queued.append { [weak self] in self?.sync(path, text: text) } }
            return
        }
        if let known = documents[path] {
            guard known.text != text else { return }
            let version = known.version + 1
            documents[path] = (version, text)
            notify("textDocument/didChange", [
                "textDocument": ["uri": LSP.uri(for: path), "version": version],
                "contentChanges": [["text": text]],
            ])
        } else {
            documents[path] = (1, text)
            notify("textDocument/didOpen", [
                "textDocument": ["uri": LSP.uri(for: path), "languageId": LSP.languageID(for: path), "version": 1, "text": text],
            ])
        }
    }

    func close(_ path: String) {
        guard state == .running, documents.removeValue(forKey: path) != nil else { return }
        notify("textDocument/didClose", ["textDocument": ["uri": LSP.uri(for: path)]])
    }

    // MARK: The conversation

    private func initialize() {
        let folder: [String: Any] = ["uri": LSP.uri(for: root), "name": (root as NSString).lastPathComponent]
        let params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "clientInfo": ["name": "Farol"],
            "rootUri": LSP.uri(for: root),
            "workspaceFolders": [folder],
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "workspace": ["workspaceFolders": true, "configuration": true],
                "textDocument": [
                    "synchronization": ["dynamicRegistration": false],
                    "definition": ["linkSupport": true],
                    "references": [String: Any](),
                ],
            ],
        ]
        let id = takeID()
        pending[id] = { [weak self] result in
            guard let self, state == .starting else { return }
            guard result != nil else { return state = .failed("It didn't answer when Farol started it.") }
            version = LSP.version(((result as? [String: Any])?["serverInfo"] as? [String: Any])?["version"] as? String)
            notify("initialized", [:])
            state = .running
            let waiting = queued
            queued = []
            waiting.forEach { $0() }
        }
        send(["jsonrpc": "2.0", "id": id, "method": "initialize", "params": params])
    }

    private func received(_ data: Data) {
        for message in reader.read(data) {
            if let method = message["method"] as? String {
                if let id = message["id"] { answer(method, id: id, params: message["params"]) }
                if method == "window/logMessage" || method == "window/showMessage",
                   let text = (message["params"] as? [String: Any])?["message"] as? String {
                    append(text + "\n")
                }
            } else if let id = message["id"] as? Int {
                if let error = message["error"] as? [String: Any] { append("Error: \(error["message"] ?? error)\n") }
                pending.removeValue(forKey: id)?(message["error"] == nil ? (message["result"] ?? NSNull()) : nil)
            }
        }
    }

    /// The server asks things too, and some wait for the answer before going on. Farol has no settings to give, so it says so.
    private func answer(_ method: String, id: Any, params: Any?) {
        let result: Any = if method == "workspace/configuration" {
            Array(repeating: NSNull(), count: ((params as? [String: Any])?["items"] as? [Any])?.count ?? 0)
        } else {
            NSNull()
        }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func ended(status: Int32) {
        guard process != nil else { return }
        process = nil
        input = nil
        pending.values.forEach { $0(nil) }
        pending = [:]
        queued = []
        documents = [:]
        state = .failed("It stopped with status \(status). Open Logs shows why.")
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ message: [String: Any]) {
        guard let input, let data = LSP.frame(message) else { return }
        writes.async { try? input.write(contentsOf: data) }
    }

    private func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func append(_ text: String) {
        log += text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }
}
