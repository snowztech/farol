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

@Test func findsAWrappedPairingLinkOnScreen() {
    let code = String(repeating: "eyJyZWxheSI6IndzczovL3JlbGF5", count: 3)
    let screen = """
    Scan this from Farol on your phone. It works once, for two minutes.
    ▄▄▄▄▄▄▄ ▄ ▄▄
    https://farol.sh/pair#\(code.prefix(40))
    \(code.dropFirst(40))
    Paired with Phone.
    """
    #expect(ServerSetup.pairingLink(in: screen)?.absoluteString == "https://farol.sh/pair#" + code)
    #expect(ServerSetup.pairingLink(in: "no link here") == nil)
}

/// Runs the setup script against a fake farol-host that writes down how it was called.
private func runSetup(pairedAlready: Bool) throws -> [String] {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("farol-host-\(UUID())")
    let bin = home.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let fake = bin.appendingPathComponent("farol-host")
    try """
    #!/bin/sh
    echo "$*" >> "$HOME/calls"
    [ "$1" = devices ] && \(pairedAlready ? "echo \"Lucas's Mac\"" : "true")
    exit 0
    """.write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", ServerSetup.script(deviceName: "Lucas's Mac")]
    process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return try String(contentsOf: home.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n").map(String.init)
}

@Test func setupPairsThisMacWhenSetupDidNot() throws {
    #expect(try runSetup(pairedAlready: false) == ["forget Lucas's Mac", "setup", "devices", "pair"])
}

@Test func setupSkipsPairingWhenSetupAlreadyPairedThisMac() throws {
    #expect(try runSetup(pairedAlready: true) == ["forget Lucas's Mac", "setup", "devices"])
}

@Test func setupCommandKeepsTheScriptWholeThroughSSH() {
    let command = ServerSetup.command(ssh: "hetzner", deviceName: "Lucas's Mac")
    #expect(command.hasPrefix("ssh -t 'hetzner' "))
    #expect(command.contains("farol.sh/host.sh"))
}
