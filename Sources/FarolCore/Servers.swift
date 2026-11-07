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

    /// Every ssh Farol runs shares one connection per server, kept ten minutes after the last one closes.
    /// A click then opens at once, and a password typed in setup isn't asked again.
    public static let connectionFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".farol/ssh")
    public static var sshOptions: [String] {
        ["-o", "ControlMaster=auto", "-o", "ControlPath=\(connectionFolder.path)/%C", "-o", "ControlPersist=10m"]
    }
    private static var ssh: String { "ssh " + sshOptions.map(NewTask.shellQuoted).joined(separator: " ") }

    /// Where the setup script hands the server's link to Farol: the terminal's title, which never wraps and isn't shown in the text.
    static let titlePrefix = "farol-host "

    /// What runs on the server, in a terminal you can see, so a password, a host key or sudo can be answered there.
    /// It installs or upgrades farol-host, sets the machine up without a phone code, then lets this Mac in by its key.
    public static func script(deviceKey: Data, deviceName: String) -> String {
        """
        set -e
        printf '\\nInstalling the latest farol-host…\\n\\n'
        curl -fsSL https://farol.sh/host.sh | sh
        fh="$HOME/.local/bin/farol-host"
        "$fh" setup --no-pair
        link=$("$fh" trust \(deviceKey.base64EncodedString()) \(NewTask.shellQuoted(deviceName)))
        printf '\\033]2;\(titlePrefix)%s\\007' "$link"
        printf '\\nDone. This Mac can see the agents here now.\\n'
        sleep 2
        """
    }

    /// The command for the session that sets a server up. The script goes as one encoded word, so the terminal shows only what it prints.
    public static func command(ssh server: String, deviceKey: Data, deviceName: String) -> String {
        let encoded = Data(script(deviceKey: deviceKey, deviceName: deviceName).utf8).base64EncodedString()
        return "clear && \(ssh) -t \(NewTask.shellQuoted(server)) 'echo \(encoded) | base64 -d | sh'"
    }

    /// The server's link, once the setup script set it as the terminal's title.
    public static func trustedLink(inTitle title: String) -> URL? {
        guard title.hasPrefix(titlePrefix + "https://farol.sh/pair#") else { return nil }
        return URL(string: String(title.dropFirst(titlePrefix.count)).trimmingCharacters(in: .whitespaces))
    }

    /// Opens a server's tmux window in this terminal. Attaching to a window makes it the one on screen.
    /// The server may not know this terminal's own TERM, so tmux is told one every server has.
    public static func attach(ssh server: String, window: String) -> String {
        "\(ssh) -t \(NewTask.shellQuoted(server)) " + NewTask.shellQuoted("TERM=xterm-256color tmux attach-session -t " + NewTask.shellQuoted(window))
    }

    /// Makes a tmux session on the server and prints its window, with no terminal, so the session opened next knows which it is.
    public static func newWindowArguments(ssh server: String) -> [String] {
        sshOptions + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", server, "tmux new-session -d -P -F '#{window_id}'"]
    }

    /// A new tmux session on the server in this terminal, for when ssh can't run without one, like a host that asks for a password.
    public static func newSession(ssh server: String) -> String {
        "\(ssh) -t \(NewTask.shellQuoted(server)) 'TERM=xterm-256color tmux new-session'"
    }

    /// Tells a server to stop letting this Mac in, for when it's offline and can't hear it through the relay.
    public static func forgetArguments(ssh server: String, deviceName: String) -> [String] {
        sshOptions + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", server,
                      "\"$HOME/.local/bin/farol-host\" forget \(NewTask.shellQuoted(deviceName))"]
    }

    /// Shows a phone code on the server, with no terminal, so Farol can draw it in a sheet. It waits until a phone scans it.
    public static func pairArguments(ssh server: String) -> [String] {
        sshOptions + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", server, "\"$HOME/.local/bin/farol-host\" pair"]
    }

    /// The phone code in a terminal, for a server whose ssh asks for a password.
    public static func pairInTerminal(ssh server: String) -> String {
        "\(ssh) -t \(NewTask.shellQuoted(server)) '\"$HOME/.local/bin/farol-host\" pair'"
    }

    /// What one line of `farol-host pair` says: the code to show, or the phone that scanned it.
    public enum PairLine: Equatable {
        case code(URL)
        case paired(String)
    }

    public static func pairLine(_ line: String) -> PairLine? {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("https://farol.sh/pair#"), let link = URL(string: text) { return .code(link) }
        if text.hasPrefix("Paired with "), text.hasSuffix(".") {
            return .paired(String(text.dropFirst("Paired with ".count).dropLast()))
        }
        return nil
    }

    /// Whether what tmux printed is a window id, like "@3".
    public static func isWindow(_ text: String) -> Bool {
        text.count > 1 && text.hasPrefix("@") && text.dropFirst().allSatisfy(\.isNumber)
    }
}
