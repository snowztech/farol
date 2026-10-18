import Darwin
import Foundation

/// The TCP ports a session's programs listen on, like a dev server an agent started in the background.
public enum Ports {
    /// The ports `roots` and every program they started listen on, lowest first. Runs lsof, so call it off the main thread.
    public static func listening(under roots: [pid_t]) -> [Int] {
        let pids = descendants(of: Set(roots), parents: parents())
        guard !pids.isEmpty else { return [] }
        // Every listening socket on the Mac, a few dozen at most. Naming the processes instead fails outright when one has just exited.
        guard let output = try? Git.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], in: "/") else { return [] }
        return ports(fromLsof: output, of: pids)
    }

    /// `roots` and everything under them, from each process's parent.
    static func descendants(of roots: Set<pid_t>, parents: [pid_t: pid_t]) -> Set<pid_t> {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, parent) in parents { children[parent, default: []].append(pid) }
        var found = roots.filter { parents[$0] != nil }
        var queue = Array(found)
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] where found.insert(child).inserted { queue.append(child) }
        }
        return found
    }

    /// Where macOS picks a port for a program that asks for any free one, as agents, editors and language servers do for their own use.
    /// A server meant to be opened picks its port, like 3000 or 5173, so these are left out.
    static let picked = 49152...65535

    /// lsof's field output: a `p1234` line for each process, then a line like `n*:3000` or `n127.0.0.1:5173` for each of its sockets.
    /// IPv4 and IPv6 often list the same port.
    static func ports(fromLsof output: String, of pids: Set<pid_t>) -> [Int] {
        var pid: pid_t?
        var ports = Set<Int>()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = pid_t(line.dropFirst())
            } else if line.hasPrefix("n"), let pid, pids.contains(pid), let colon = line.lastIndex(of: ":"),
                      let port = Int(line[line.index(after: colon)...]), !picked.contains(port) {
                ports.insert(port)
            }
        }
        return ports.sorted()
    }

    /// Every process's parent, in one call.
    private static func parents() -> [pid_t: pid_t] {
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&query, 4, nil, &size, nil, 0) == 0 else { return [:] }
        // Room for processes started between the two calls.
        size += size / 8
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&query, 4, &procs, &size, nil, 0) == 0 else { return [:] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        return Dictionary(procs.prefix(count).map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid) }, uniquingKeysWith: { first, _ in first })
    }
}
