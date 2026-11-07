import Foundation

/// A machine running `farol-host`, whose agents show in the sidebar. The Mac pairs with it as a phone does and opens its sessions over ssh.
public struct Server: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// What `ssh` is given: a Host from `~/.ssh/config`, or `user@host`.
    public var ssh: String
    /// The pairing link the server showed, which holds its relay and its public key.
    public var link: URL

    public init(id: UUID = UUID(), name: String, ssh: String, link: URL) {
        self.id = id
        self.name = name
        self.ssh = ssh
        self.link = link
    }

    /// The name a server gets in the sidebar: the ssh Host, or the machine part of `user@host`.
    public static func name(for ssh: String) -> String {
        let machine = ssh.split(separator: "@").last.map(String.init) ?? ssh
        return machine.split(separator: ".").first.map(String.init) ?? machine
    }
}

/// The servers you added, in `~/.farol/servers.json`. Their keys stay on each side, so the file holds nothing secret.
public struct ServerList {
    public let file: URL

    public static let `default` = ServerList(
        file: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".farol/servers.json"))

    public init(file: URL) {
        self.file = file
    }

    public func load() -> [Server] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Server].self, from: data)) ?? []
    }

    public func save(_ servers: [Server]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(servers).write(to: file, options: .atomic)
    }
}

public enum ServerSetup {
    /// The hosts in an ssh config, in order, without patterns like `*` that name no one machine.
    public static func hosts(inSSHConfig text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.first?.lowercased() == "host" else { return [] }
            return words.dropFirst().map(String.init).filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
        }
        .filter { seen.insert($0).inserted }
    }

    public static var sshHosts: [String] {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        return hosts(inSSHConfig: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
    }

    /// What runs on the server, in a terminal you can see, so a password, a host key or sudo can be answered there.
    /// It installs farol-host when it's missing, runs its setup, then shows a pairing code unless setup already showed one this Mac used.
    /// A Mac paired before is forgotten first, so adding a server again always pairs anew.
    public static func script(deviceName: String) -> String {
        let name = NewTask.shellQuoted(deviceName)
        return """
        set -e
        fh="$HOME/.local/bin/farol-host"
        [ -x "$fh" ] || curl -fsSL https://farol.sh/host.sh | sh
        "$fh" forget \(name) >/dev/null 2>&1 || true
        "$fh" setup
        "$fh" devices | grep -qxF \(name) || "$fh" pair
        """
    }

    /// The command for the session that sets a server up.
    public static func command(ssh: String, deviceName: String) -> String {
        "ssh -t \(NewTask.shellQuoted(ssh)) \(NewTask.shellQuoted("sh -c " + NewTask.shellQuoted(script(deviceName: deviceName))))"
    }

    /// Opens a server's tmux window in this terminal. Attaching to a window makes it the one on screen.
    public static func attach(ssh: String, window: String) -> String {
        "ssh -t \(NewTask.shellQuoted(ssh)) " + NewTask.shellQuoted("tmux attach-session -t " + NewTask.shellQuoted(window))
    }

    /// Makes a tmux session on the server and prints its window, with no terminal, so the session opened next knows which it is.
    public static func newWindowArguments(ssh: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", ssh, "tmux new-session -d -P -F '#{window_id}'"]
    }

    /// A new tmux session on the server in this terminal, for when ssh can't run without one, like a host that asks for a password.
    public static func newSession(ssh: String) -> String {
        "ssh -t \(NewTask.shellQuoted(ssh)) tmux new-session"
    }

    /// Whether what tmux printed is a window id, like "@3".
    public static func isWindow(_ text: String) -> Bool {
        text.count > 1 && text.hasPrefix("@") && text.dropFirst().allSatisfy(\.isNumber)
    }

    /// The last pairing link farol-host printed, found on screen. A link wider than the terminal wraps onto lines that hold nothing else.
    public static func pairingLink(in screen: String) -> URL? {
        let prefix = "https://farol.sh/pair#"
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.lastIndex(where: { $0.contains(prefix) }) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let isCode = { (text: Substring) in !text.isEmpty && text.unicodeScalars.allSatisfy(allowed.contains) }
        let start = lines[first].range(of: prefix)!.upperBound
        let tail = lines[first][start...]
        guard isCode(tail) else { return nil }
        var code = String(tail)
        for line in lines[(first + 1)...] {
            guard isCode(Substring(line)) else { break }
            code += line
        }
        return code.count > 20 ? URL(string: prefix + code) : nil
    }
}
