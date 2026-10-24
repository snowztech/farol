import FarolCore
import Foundation

/// `farol sessions`, `task`, `send`, `wait` and `read`: one request to Farol over its socket, and its answer printed.
/// Unlike the hooks, these say when something is wrong, on standard error and with a failing exit code, so an agent notices.
enum Control {
    static let usage = """
    usage: farol sessions [--json]
           farol task <what to do> [--agent claude|codex] [--repo <folder>] [--json]
           farol send <session> <message>
           farol wait <session> [--timeout <seconds>] [--json]
           farol read <session>

    sessions lists Farol's sessions: id, status, name, agent and branch, and what one waiting asks.
    task starts an agent on a task in a new worktree of this repository, or of --repo, and prints its session.
    send types a message to the agent in a session, as you would.
    wait returns once the session's agent needs someone or is done, or after the timeout, \(Int(ControlCommand.waitLimit)) seconds unless set.
    read prints the last message of the agent in a session.

    A session is named by its id, the start of it, or its name. Starting tasks and sending messages
    needs Settings → Agents → Let agents start tasks and message sessions.
    """

    static func run(_ arguments: [String]) -> Never {
        let command: ControlCommand
        switch ControlCommand.parse(arguments) {
        case .success(let parsed): command = parsed
        case .failure(let usage): fail("\(usage.message)\n\n\(Self.usage)", code: 64)
        }
        let environment = ProcessInfo.processInfo.environment
        var action = command.action
        // A folder named on the command line is the caller's, so it is made whole here, where the caller is.
        if case .task(let text, let repo?, let agent) = action {
            action = .task(text: text, repo: URL(fileURLWithPath: repo, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardized.path, agent: agent)
        }
        let reply: ControlReply
        do {
            guard let answer = try StatusClient.control(ControlRequest(pane: environment["FAROL_PANE"], action: action), to: socket(in: environment)) else {
                fail("Farol did not answer. This command needs a newer Farol: click Update in Farol, or download it again.")
            }
            reply = answer
        } catch {
            fail(environment["FAROL_SOCKET"] == nil ? "Farol is not running. Open Farol and run this again." : "Farol is not reachable from here. An agent in a sandbox, like Codex, needs to run farol outside it.")
        }
        if let error = reply.error { fail(error) }
        if command.json {
            print(ControlOutput.json(reply))
            exit(0)
        }
        switch action {
        case .sessions:
            print(reply.sessions.map(ControlOutput.lines) ?? "")
        case .task:
            reply.session.map { print("Started \(ControlOutput.line($0))") }
        case .send:
            print("Sent.")
        case .wait:
            reply.session.map { print(ControlOutput.line($0)) }
            // It ran out before the session needed someone or was done: a different exit, so a script knows.
            if let note = reply.note {
                FileHandle.standardError.write(Data("farol: \(note)\n".utf8))
                exit(2)
            }
        case .read:
            print(reply.text ?? "")
        }
        exit(0)
    }

    /// Farol's socket: the one this pane reports to, or else the installed Farol's, so a terminal outside Farol reaches it too.
    private static func socket(in environment: [String: String]) -> String {
        if let socket = environment["FAROL_SOCKET"] { return socket }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Farol/dev.farol.Farol.sock").path
    }

    private static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("farol: \(message)\n".utf8))
        exit(code)
    }
}
