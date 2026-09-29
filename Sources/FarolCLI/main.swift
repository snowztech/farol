import FarolCore
import Foundation

let usage = """
usage: farol status working|waiting|done|clear|subagent-start|subagent-stop

Reports what the agent in this pane is doing, so Farol's sidebar can show it.
subagent-start and subagent-stop keep the pane working while a background agent runs.
Outside Farol it does nothing, so hooks that call it are safe in any terminal.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, arguments[0] == "status" else {
    print(usage)
    exit(arguments.first == "help" || arguments.first == "--help" ? 0 : 64)
}

guard let event = AgentEvent(rawValue: arguments[1]) else {
    FileHandle.standardError.write("farol: unknown status \(arguments[1])\n\n\(usage)\n".data(using: .utf8)!)
    exit(64)
}

// Farol sets these in every shell it starts. Without them this isn't a Farol pane.
let environment = ProcessInfo.processInfo.environment
guard let pane = environment["FAROL_PANE"], let socket = environment["FAROL_SOCKET"] else { exit(0) }

do {
    try StatusClient.send(StatusMessage(pane: pane, event: event), to: socket)
} catch {
    // Farol may have quit while the agent kept running. A hook must never fail the agent over that.
    exit(0)
}
