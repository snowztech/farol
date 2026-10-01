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
    static func run(_ executable: String, _ arguments: [String], in directory: String, trimming: Bool = true) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = URL(fileURLWithPath: executable).lastPathComponent
            throw GitError(description: message.isEmpty ? "\(name) \(arguments.joined(separator: " ")) failed" : message)
        }
        let text = String(decoding: out, as: UTF8.self)
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
