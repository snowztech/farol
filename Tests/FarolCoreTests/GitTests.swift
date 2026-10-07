import Foundation
import Testing
@testable import FarolCore

@Test func aCommandThatFillsStderrFirstDoesNotStall() throws {
    // More than the pipe holds on stderr before anything on stdout.
    let script = "head -c 200000 /dev/zero | tr '\\0' e >&2 && echo done"
    #expect(try Git.run("/bin/sh", ["-c", script], in: NSTemporaryDirectory()) == "done")
}

@Test func readsThePathFromAShell() {
    #expect(Git.path(from: "/bin/sh")?.contains("/usr/bin") == true)
}

@Test func givesUpOnAShellThatHangs() throws {
    let shell = FileManager.default.temporaryDirectory.appendingPathComponent("farol-shell-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: shell) }
    try "#!/bin/sh\nsleep 30\n".write(to: shell, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
    #expect(Git.path(from: shell.path, timeout: 0.5) == nil)
}

@Test func aHelperLeftRunningDoesNotHoldThePathBack() throws {
    let shell = FileManager.default.temporaryDirectory.appendingPathComponent("farol-shell-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: shell) }
    // Stands in for a startup file that starts something in the background.
    try "#!/bin/sh\nsleep 30 &\nexec /bin/sh \"$@\"\n".write(to: shell, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
    #expect(Git.path(from: shell.path, timeout: 5)?.contains("/usr/bin") == true)
}
