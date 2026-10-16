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

/// What the hook was given on its input, when it was given one. Claude Code writes JSON there and closes it.
/// A terminal or an input left open is never waited on for more than a moment, since a hook must not hold the agent up.
func hookInput() -> Data? {
    let input = FileHandle.standardInput.fileDescriptor
    guard isatty(input) == 0 else { return nil }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    let deadline = Date().addingTimeInterval(0.3)
    while true {
        var ready = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
        let left = Int32(deadline.timeIntervalSinceNow * 1000)
        guard left > 0, poll(&ready, 1, left) > 0 else { return nil }
        let count = read(input, &buffer, buffer.count)
        guard count > 0 else { return count == 0 ? data : nil }
        data.append(contentsOf: buffer[..<count])
    }
}

do {
    let input = hookInput()
    let request = event == .waiting ? input.flatMap(AgentRequest.init(hookInput:)) : nil
    try StatusClient.send(StatusMessage(pane: pane, event: event, conversation: input.flatMap(AgentConversation.init(hookInput:)), request: request), to: socket)
} catch {
    // Farol may have quit while the agent kept running. A hook must never fail the agent over that.
    exit(0)
}
