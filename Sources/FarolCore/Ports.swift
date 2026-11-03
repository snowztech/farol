import Darwin
import Foundation

/// The TCP ports a session's programs listen on, like a dev server an agent started in the background.
public enum Ports {
    /// The ports `roots` and every program they started serve pages on, lowest first. Runs lsof, so call it off the main thread.
    public static func listening(under roots: [pid_t]) -> [Int] {
        let pids = descendants(of: Set(roots), parents: parents())
        guard !pids.isEmpty else { return [] }
        // Every listening socket on the Mac, a few dozen at most. Naming the processes instead fails outright when one has just exited.
        guard let output = try? Git.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], in: "/") else { return [] }
        let all = sockets(fromLsof: output)
        let ours = all.filter { pids.contains($0.pid) }
        return Set(servingPages(ours, among: all).map(\.port)).sorted()
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

    struct Socket: Hashable {
        let pid: pid_t
        let port: Int
    }

    /// lsof's field output: a `p1234` line for each process, then a line like `n*:3000` or `n127.0.0.1:5173` for each of its sockets.
    /// IPv4 and IPv6 often list the same port.
    static func sockets(fromLsof output: String) -> Set<Socket> {
        var pid: pid_t?
        var sockets = Set<Socket>()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = pid_t(line.dropFirst())
            } else if line.hasPrefix("n"), let pid, let colon = line.lastIndex(of: ":"),
                      let port = Int(line[line.index(after: colon)...]), !picked.contains(port) {
                sockets.insert(Socket(pid: pid, port: port))
            }
        }
        return sockets
    }

    /// A socket keeps its protocol while its process runs, so each server is asked once, not at every prompt, and its log stays quiet.
    private static let lock = NSLock()
    private static var answers: [Socket: Bool] = [:]

    /// The sockets in `sockets` a browser can open. `all` is every socket still listening, to forget the ones that closed.
    private static func servingPages(_ sockets: Set<Socket>, among all: Set<Socket>) -> [Socket] {
        lock.lock()
        answers = answers.filter { all.contains($0.key) }
        let unasked = sockets.filter { answers[$0] == nil }
        lock.unlock()
        let asked = Array(unasked)
        DispatchQueue.concurrentPerform(iterations: asked.count) { index in
            guard let serves = servesPages(asked[index].port) else { return }
            lock.lock()
            answers[asked[index]] = serves
            lock.unlock()
        }
        lock.lock()
        defer { lock.unlock() }
        return sockets.filter { answers[$0] == true }
    }

    private static let probe: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    /// Whether the port answers HTTP with something other than 426.
    /// A database answers no HTTP at all, and a bare websocket, like Vite's hot reload, asks for an upgrade.
    /// Nil when it doesn't answer in time, like Next.js compiling its first page, so it's asked again next time.
    static func servesPages(_ port: Int) -> Bool? {
        var request = URLRequest(url: URL(string: "http://localhost:\(port)/")!, timeoutInterval: 1)
        request.httpMethod = "HEAD"
        var answer: Bool?
        let done = DispatchSemaphore(value: 0)
        probe.dataTask(with: request) { _, response, error in
            if let status = (response as? HTTPURLResponse)?.statusCode {
                answer = status != 426
            } else if (error as? URLError)?.code != .timedOut {
                answer = false
            }
            done.signal()
        }.resume()
        done.wait()
        return answer
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
