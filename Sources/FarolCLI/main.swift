import FarolCore
import Foundation

let usage = """
usage: farol status working|waiting|done|clear|quit [--agent name]

Reports what the agent in this pane is doing, so Farol's sidebar can show it.
--agent names the agent, like claude or codex, so the sidebar can show which one it is.
quit clears the status and tells Farol the agent has exited.
Outside Farol it does nothing, so hooks that call it are safe in any terminal.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
let named = arguments.count == 4 && arguments[2] == "--agent"
guard arguments.count == 2 || named, arguments[0] == "status" else {
    print(usage)
    exit(arguments.first == "help" || arguments.first == "--help" ? 0 : 64)
}

let status: AgentStatus?
// Quit is a clear that also forgets the agent, so it never carries a name.
let quitting = arguments[1] == "quit"
if arguments[1] == "clear" || quitting {
    status = nil
} else if let parsed = AgentStatus(rawValue: arguments[1]) {
    status = parsed
} else {
    FileHandle.standardError.write("farol: unknown status \(arguments[1])\n\n\(usage)\n".data(using: .utf8)!)
    exit(64)
}

// Farol sets these in every shell it starts. Without them this isn't a Farol pane.
let environment = ProcessInfo.processInfo.environment
guard let pane = environment["FAROL_PANE"], let socket = environment["FAROL_SOCKET"] else { exit(0) }

do {
    try StatusClient.send(StatusMessage(pane: pane, status: status, agent: named && !quitting ? arguments[3] : nil), to: socket)
} catch {
    // Farol may have quit while the agent kept running. A hook must never fail the agent over that.
    exit(0)
}
