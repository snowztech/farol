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
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }
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
