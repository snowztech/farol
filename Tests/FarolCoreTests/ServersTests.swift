import Foundation
import Testing
@testable import FarolCore

@Test func readsHostsFromAnSSHConfig() {
    let config = """
    Host *
      ServerAliveInterval 30
    Host hetzner prod-?? !bastion
      HostName 1.2.3.4
    host mac-mini
    Host hetzner
    """
    #expect(ServerSetup.hosts(inSSHConfig: config) == ["hetzner", "mac-mini"])
}

@Test func namesAServerAfterItsMachine() {
    #expect(Server.name(for: "hetzner") == "hetzner")
    #expect(Server.name(for: "root@box.example.com") == "box")
}

@Test func keepsServersAcrossLaunches() throws {
    let list = ServerList(file: FileManager.default.temporaryDirectory.appendingPathComponent("farol-servers-\(UUID()).json"))
    #expect(list.load().isEmpty)
    let server = Server(name: "hetzner", ssh: "hetzner", link: URL(string: "https://farol.sh/pair#abc")!)
    try list.save([server])
    #expect(list.load() == [server])
}

@Test func readsTheServersLinkFromTheTitle() {
    #expect(ServerSetup.trustedLink(inTitle: "farol-host https://farol.sh/pair#abc")?.absoluteString == "https://farol.sh/pair#abc")
    #expect(ServerSetup.trustedLink(inTitle: "vim notes.md") == nil)
}

/// Runs the setup script with a fake curl and farol-host that write down how they were called.
@Test func setupUpgradesSetsUpWithoutAPhoneCodeThenTrustsThisMac() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("farol-host-\(UUID())")
    let bin = home.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let fakes = [
        "curl": "echo \"curl $*\" >> \"$HOME/calls\"",
        "farol-host": "echo \"$*\" >> \"$HOME/calls\"\n[ \"$1\" = trust ] && echo https://farol.sh/pair#xyz\nexit 0",
    ]
    for (name, body) in fakes {
        let file = bin.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    let key = Data(repeating: 7, count: 32)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", ServerSetup.script(deviceKey: key, deviceName: "Lucas's Mac").replacingOccurrences(of: "sleep 2", with: "")]
    process.environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let calls = try String(contentsOf: home.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(calls == ["curl -fsSL https://farol.sh/host.sh", "setup --no-pair", "trust \(key.base64EncodedString()) Lucas's Mac"])
    #expect(printed.contains("\u{1B}]2;farol-host https://farol.sh/pair#xyz\u{07}"))
}

@Test func setupCommandSendsTheScriptAsOneWord() throws {
    let key = Data(repeating: 7, count: 32)
    let command = ServerSetup.command(ssh: "hetzner", deviceKey: key, deviceName: "Lucas's Mac")
    #expect(!command.contains("\n"))
    let encoded = try #require(command.split(separator: " ").first { $0.count > 100 })
    #expect(Data(base64Encoded: String(encoded)).map { String(decoding: $0, as: UTF8.self) }
            == ServerSetup.script(deviceKey: key, deviceName: "Lucas's Mac"))
}

@Test func attachingNamesTheWindowForTheServersShell() throws {
    let command = ServerSetup.attach(ssh: "hetzner", window: "@3")
    #expect(command.contains("ControlPersist"))
    // What the server's shell gets once this Mac's shell has taken its quotes off, then what tmux gets from that.
    let remote = String(command[command.range(of: "'hetzner' ")!.upperBound...])
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "sh -c \"printf '%s|' $(printf '%s' \(remote))\""]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    let words = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(words == "TERM=xterm-256color|tmux|attach-session|-t|@3|")
}

@Test func tellsAWindowIDFromOtherOutput() {
    #expect(ServerSetup.isWindow("@12"))
    #expect(!ServerSetup.isWindow("@"))
    #expect(!ServerSetup.isWindow("no server running"))
}

@Test func readsWhatFarolHostPairSays() {
    #expect(ServerSetup.pairLine("https://farol.sh/pair#abc") == .code(URL(string: "https://farol.sh/pair#abc")!))
    #expect(ServerSetup.pairLine("Paired with Lucas's iPhone.") == .paired("Lucas's iPhone"))
    #expect(ServerSetup.pairLine("Scan this from Farol on your phone. It works once, for two minutes.") == nil)
    #expect(ServerSetup.pairLine("▄▄▄ ▄ ▄▄▄") == nil)
}

@Test func endingASessionNamesItsWindow() {
    #expect(ServerSetup.killWindowArguments(ssh: "vps", window: "@3").suffix(2) == ["vps", "tmux kill-window -t '@3'"])
    #expect(ServerSetup.shell(ssh: "vps").hasSuffix("-t 'vps'"))
}
