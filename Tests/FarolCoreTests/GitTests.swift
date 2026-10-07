import Foundation
import Testing
@testable import FarolCore

@Test func aCommandThatFillsStderrFirstDoesNotStall() throws {
    // More than the pipe holds on stderr before anything on stdout.
    let script = "head -c 200000 /dev/zero | tr '\\0' e >&2 && echo done"
    #expect(try Git.run("/bin/sh", ["-c", script], in: NSTemporaryDirectory()) == "done")
}
