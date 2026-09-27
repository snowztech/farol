import Foundation

public struct GitError: Error, CustomStringConvertible {
    public let description: String
}

/// Runs the git command line tool. Shelling out keeps Farol's behavior identical to the user's own git.
public enum Git {
    @discardableResult
    static func run(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
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
            throw GitError(description: message.isEmpty ? "git \(arguments.joined(separator: " ")) failed" : message)
        }
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The main checkout of the repo that contains `directory`, even when called from inside a worktree.
    public static func repoRoot(of directory: String) -> String? {
        guard let common = try? run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory) else {
            return nil
        }
        return URL(fileURLWithPath: common).deletingLastPathComponent().path
    }

    /// The checked out branch, or nil outside a repo or on a detached HEAD.
    public static func branch(of directory: String) -> String? {
        guard let name = try? run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory) else { return nil }
        return name.isEmpty ? nil : name
    }
}
