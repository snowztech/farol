import FarolCore
import Foundation

let usage = """
usage: farol status working|waiting|done|clear|subagent-start|subagent-stop

Reports what the agent in this pane is doing, so Farol's sidebar can show it.
subagent-start and subagent-stop keep the pane working while a background agent runs.
With waiting, the hook's JSON on stdin is read for the question or message to show in the notification.
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

/// The hook's JSON arrives on stdin. A pipe that never closes must not hold the agent, so this gives up after a moment.
func hookInput() -> Data {
    guard isatty(STDIN_FILENO) == 0 else { return Data() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    while data.count < 64 * 1024, poll(&descriptor, 1, 200) > 0 {
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        guard count > 0 else { break }
        data.append(contentsOf: buffer[0..<count])
    }
    return data
}

// Only a waiting agent has something to ask.
let prompt = event == .waiting ? AgentPrompt(hookInput: hookInput()) : nil

do {
    try StatusClient.send(StatusMessage(pane: pane, event: event, prompt: prompt), to: socket)
} catch {
    // Farol may have quit while the agent kept running. A hook must never fail the agent over that.
    exit(0)
}
