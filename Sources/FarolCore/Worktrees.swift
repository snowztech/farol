import Foundation

/// Git worktrees for sessions. Each lives outside the repo, in `<base>/<repo>/<branch>`, so the repo stays clean.
public struct Worktrees {
    public let base: URL

    public static let `default` = Worktrees(
        base: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".farol/worktrees"))

    public init(base: URL) {
        self.base = base
    }

    public func contains(_ path: String) -> Bool {
        let resolved = { (url: URL) in url.resolvingSymlinksInPath().path }
        return resolved(URL(fileURLWithPath: path)).hasPrefix(resolved(base) + "/")
    }

    /// The worktree folder a path is in, even from a subfolder, or nil outside Farol's worktrees.
    public func root(of path: String) -> String? {
        guard contains(path) else { return nil }
        let base = base.resolvingSymlinksInPath().pathComponents
        let parts = URL(fileURLWithPath: path).resolvingSymlinksInPath().pathComponents
        guard parts.count >= base.count + 2 else { return nil }
        return NSString.path(withComponents: Array(parts.prefix(base.count + 2)))
    }

    /// Turns what the user typed into a branch name git accepts, or nil if nothing usable is left.
    public static func branchName(from input: String) -> String? {
        let words = input.split(whereSeparator: \.isWhitespace).joined(separator: "-")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./"))
        let cleaned = String(words.unicodeScalars.filter(allowed.contains))
            .replacingOccurrences(of: "..", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-./"))
        guard !cleaned.isEmpty, (try? Git.run(["check-ref-format", "--branch", cleaned], in: "/")) != nil else {
            return nil
        }
        return cleaned
    }

    /// Creates a worktree for `branch` from the repo containing `directory`.
    /// A new branch starts from whatever `directory` has checked out. An existing branch is checked out as is.
    public func create(branch: String, from directory: String) throws -> String {
        guard let root = Git.repoRoot(of: directory) else {
            throw GitError(description: "\(directory) is not inside a git repository.")
        }
        let repoName = URL(fileURLWithPath: root).lastPathComponent
        let path = base.appendingPathComponent(repoName)
            .appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-")).path
        guard !FileManager.default.fileExists(atPath: path) else {
            throw GitError(description: "A worktree already exists at \(path).")
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)

        let exists = (try? Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: directory)) != nil
        if exists {
            try Git.run(["worktree", "add", path, branch], in: directory)
        } else {
            try Git.run(["worktree", "add", "-b", branch, path], in: directory)
        }
        return path
    }

    /// Modified or new files that removing the worktree would lose. Git refuses to remove it while there are any.
    public func hasUncommittedChanges(_ path: String) -> Bool {
        let status = (try? Git.run(["status", "--porcelain"], in: path)) ?? ""
        return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Removes the worktree folder but never the branch, so no commit is lost.
    /// Git refuses when there are uncommitted changes, and that error is passed on.
    public func remove(_ path: String) throws {
        guard contains(path), let root = Git.repoRoot(of: path) else {
            throw GitError(description: "\(path) is not a Farol worktree.")
        }
        try Git.run(["worktree", "remove", path], in: root)
    }
}
