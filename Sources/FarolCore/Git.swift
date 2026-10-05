import Foundation

public struct GitError: Error, CustomStringConvertible {
    public let description: String
}

/// Runs the git command line tool. Shelling out keeps Farol's behavior identical to the user's own git.
public enum Git {
    @discardableResult
    static func run(_ arguments: [String], in directory: String, trimming: Bool = true) throws -> String {
        try run("/usr/bin/git", arguments, in: directory, trimming: trimming)
    }

    /// Runs any command line tool the same way, as for the forges' own tools.
    /// Some tools report on stderr even when all is well, and `mergingErrors` returns that with the output.
    static func run(_ executable: String, _ arguments: [String], in directory: String, trimming: Bool = true,
                    mergingErrors: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        // There's no terminal to type a password into, so git fails right away instead of waiting forever.
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0", "PATH": shellPath]) { $1 }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        // Read apart, so a command that fills one pipe can't wait forever on the other being read.
        // A thread of its own, since the shared pool can run out while many of these wait.
        var err = Data()
        let read = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            err = errors.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        read.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = URL(fileURLWithPath: executable).lastPathComponent
            throw GitError(description: message.isEmpty ? "\(name) \(arguments.joined(separator: " ")) failed" : message)
        }
        let text = String(decoding: mergingErrors ? out + err : out, as: UTF8.self)
        // A diff's leading spaces are context lines, so it can't be trimmed.
        return trimming ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    /// An app opened from the Dock gets a bare PATH, so a repo's hooks can't find tools like pnpm or npx.
    /// The PATH comes from your shell instead, as it would in a terminal. It's read once, since starting a shell is slow.
    static let shellPath: String = {
        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // The marker keeps whatever the startup files print out of the PATH.
        process.arguments = ["-ilc", #"printf '\n__FAROL_PATH__%s' "$PATH""#]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return fallback }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0, let range = text.range(of: "__FAROL_PATH__", options: .backwards) else {
            return fallback
        }
        let path = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? fallback : path
    }()

    /// The main checkout of the repo that contains `directory`, even when called from inside a worktree.
    public static func repoRoot(of directory: String) -> String? {
        guard let common = try? run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory) else {
            return nil
        }
        return URL(fileURLWithPath: common).deletingLastPathComponent().path
    }

    /// The checked out branch, or nil outside a repo or on a detached HEAD.
    /// The top of the checkout the folder is in. For a worktree, the worktree itself.
    public static func topLevel(of directory: String) -> String? {
        try? run(["rev-parse", "--show-toplevel"], in: directory)
    }

    public static func branch(of directory: String) -> String? {
        guard let name = try? run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory) else { return nil }
        return name.isEmpty ? nil : name
    }
}
