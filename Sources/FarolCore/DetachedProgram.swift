import Darwin
import Foundation

/// A program running from inside a folder with no terminal, like a dev server an agent started in the background.
/// Closing a session hangs up its terminals, which stops what runs on them, but a program like this keeps running.
public struct DetachedProgram: Equatable {
    public let pid: pid_t
    /// The process group, so a dev server and the helpers it spawned read as one program.
    public let group: pid_t
    public let command: String

    /// Programs whose current folder is `folder` or one of its subfolders, oldest first.
    public static func running(in folder: String) -> [DetachedProgram] {
        let resolved = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let folder = resolved(folder)
        var pids = [pid_t](repeating: 0, count: Int(max(proc_listallpids(nil, 0), 0)) + 64)
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        return pids.prefix(Int(max(count, 0))).sorted().compactMap { pid in
            guard pid > 0, pid != getpid(), let cwd = workingDirectory(of: pid) else { return nil }
            let current = resolved(cwd)
            guard current == folder || current.hasPrefix(folder + "/") else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            // A program on a terminal stops with it, or belongs to a terminal outside Farol that it should not touch.
            guard info.pbi_flags & UInt32(PROC_FLAG_CONTROLT) == 0 else { return nil }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return DetachedProgram(pid: pid, group: pid_t(info.pbi_pgid), command: commandLine(of: pid) ?? name)
        }
    }

    /// One command per process group, in the order they started.
    public static func names(_ programs: [DetachedProgram]) -> [String] {
        var seen = Set<pid_t>()
        return programs.filter { seen.insert($0.group).inserted }.map(\.command)
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    /// The program name and its arguments, like "pnpm exec nuxt dev", which says more than "node".
    private static func commandLine(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // The layout is argc, the executable path, padding, then the arguments, each ending with a zero byte.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        guard let program = arguments.first else { return nil }
        // Some programs, like claude, rewrite their arguments in place and leave trailing spaces.
        return ([URL(fileURLWithPath: program).lastPathComponent] + arguments.dropFirst())
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
