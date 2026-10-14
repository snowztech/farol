import Darwin
import Foundation
import Testing
@testable import FarolCore

/// Starts `sleep` in its own session, with no terminal, like a dev server an agent leaves running.
private func startDetached(in folder: String) throws -> pid_t {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addchdir_np(&actions, folder)
    let words: [String] = ["/bin/sleep", "30"]
    let arguments: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
    defer { arguments.forEach { free($0) } }
    var pid: pid_t = 0
    guard posix_spawn(&pid, "/bin/sleep", &actions, &attributes, arguments, environ) == 0 else {
        throw GitError(description: "sleep did not start")
    }
    return pid
}

/// The signal that ended `pid`, or nil if it ended on its own.
private func signalThatEnded(_ pid: pid_t) -> Int32? {
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    let signal = status & 0x7f
    return signal == 0 ? nil : signal
}

@Test func findsDetachedProgramsInAFolder() throws {
    let box = try Sandbox()
    let path = try box.worktrees.create(branch: "server", from: box.repo)
    let pid = try startDetached(in: path)
    defer { kill(pid, SIGKILL); _ = signalThatEnded(pid) }

    let programs = DetachedProgram.running(in: path)
    #expect(programs.map(\.pid) == [pid])
    #expect(DetachedProgram.names(programs) == ["sleep 30"])
    #expect(!DetachedProgram.running(in: box.repo).contains { $0.pid == pid })
}

@Test func removingStopsTheProgramsItWasGiven() throws {
    let box = try Sandbox()
    let path = try box.worktrees.create(branch: "server", from: box.repo)
    let pid = try startDetached(in: path)

    try box.worktrees.remove(path, stopping: DetachedProgram.running(in: path))
    #expect(signalThatEnded(pid) == SIGTERM)
}

@Test func aRefusedRemovalStopsNothing() throws {
    let box = try Sandbox()
    let path = try box.worktrees.create(branch: "wip", from: box.repo)
    try "draft".write(toFile: path + "/notes.txt", atomically: true, encoding: .utf8)
    let pid = try startDetached(in: path)
    defer { kill(pid, SIGKILL); _ = signalThatEnded(pid) }

    #expect(throws: GitError.self) { try box.worktrees.remove(path, stopping: DetachedProgram.running(in: path)) }
    #expect(kill(pid, 0) == 0)
}
