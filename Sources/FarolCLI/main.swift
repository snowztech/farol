import FarolCore
import Foundation

let usage = """
usage: farol status working|waiting|done|clear|subagent-start|subagent-stop
       farol sessions
       farol read <session>
       farol send <session> <text>
       farol key <session> \(PaneKey.allCases.map(\.rawValue).joined(separator: "|"))

status reports what the agent in this pane is doing, so Farol's sidebar can show it.
subagent-start and subagent-stop keep the pane working while a background agent runs.
Outside Farol it does nothing, so hooks that call it are safe in any terminal.

sessions lists the sessions with their place in the sidebar, and the others take that place:
read prints what the session shows. send types text into it and key presses a key,
which Farol only allows while Remote is on.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("farol: \(message)\n\n\(usage)\n".data(using: .utf8)!)
    exit(64)
}

/// What the rest of the line asks the app, or nil when it isn't one of those commands.
func request(_ arguments: [String]) -> PaneRequest? {
    if arguments == ["sessions"] { return .sessions }
    guard arguments.count >= 2, let session = Int(arguments[1]) else { return nil }
    switch (arguments[0], arguments.count) {
    case ("read", 2): return .read(session: session)
    case ("send", 3): return .send(session: session, text: arguments[2])
    case ("key", 3): return PaneKey(rawValue: arguments[2]).map { .key(session: session, key: $0) }
    default: return nil
    }
}

if let request = request(arguments) {
    guard let socket = environment["FAROL_SOCKET"] else { fail("run this in a Farol session, or set FAROL_SOCKET") }
    do {
        switch try StatusClient.ask(request, at: socket) {
        case .text(let text): print(text, terminator: "")
        case .refused(let why):
            FileHandle.standardError.write("farol: \(why)\n".data(using: .utf8)!)
            exit(1)
        }
    } catch {
        fail("Farol did not answer: \(error.localizedDescription)")
    }
    exit(0)
}

guard arguments.count == 2, arguments[0] == "status" else {
    print(usage)
    exit(arguments.first == "help" || arguments.first == "--help" ? 0 : 64)
}

guard let event = AgentEvent(rawValue: arguments[1]) else { fail("unknown status \(arguments[1])") }

guard let pane = environment["FAROL_PANE"], let socket = environment["FAROL_SOCKET"] else { exit(0) }

do {
    try StatusClient.send(StatusMessage(pane: pane, event: event), to: socket)
} catch {
    exit(0)
}
