import Foundation

/// Git worktrees for sessions. Each lives outside the repo, in `<base>/<repo>/<branch>`, so the repo stays clean.
public struct Worktrees {
    public let base: URL

    public static let `default` = Worktrees(
        base: FarolHome.url.appendingPathComponent("worktrees"))

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
        return Self.folder(of: path, under: base, depth: 2)
    }

    /// The folder `depth` levels under `base` that `path` is in, or nil when `path` isn't that deep.
    static func folder(of path: String, under base: URL, depth: Int) -> String? {
        let base = base.resolvingSymlinksInPath().pathComponents
        let parts = URL(fileURLWithPath: path).resolvingSymlinksInPath().pathComponents
        guard parts.count >= base.count + depth else { return nil }
        return NSString.path(withComponents: Array(parts.prefix(base.count + depth)))
    }

    /// Turns what the user typed into a branch name git accepts, or nil if nothing usable is left.
    public static func branchName(from input: String) -> String? {
        let words = input.split(whereSeparator: \.isWhitespace).joined(separator: "-")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./"))
        let cleaned = String(words.unicodeScalars.filter(allowed.contains))
            .replacingOccurrences(of: "..", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-./"))
        guard !cleaned.isEmpty, isBranchName(cleaned) else { return nil }
        return cleaned
    }

    /// Git's rules for a branch name (`git check-ref-format --branch`), for the characters `branchName(from:)` keeps.
    /// Checked here rather than by running git, since the New Task sheet asks on every keystroke.
    static func isBranchName(_ name: String) -> Bool {
        name != "HEAD" && !name.hasPrefix("-") && !name.hasSuffix(".") && !name.contains("..")
            && name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
                !part.isEmpty && !part.hasPrefix(".") && !part.hasSuffix(".lock")
            }
    }

    /// Creates a worktree for `branch` from the repo containing `directory`.
    /// A new branch starts from whatever `directory` has checked out, or from the remote's latest default branch with `fromDefaultBranch`.
    /// An existing branch is checked out as is.
    public func create(branch: String, from directory: String, copyEnvironmentFiles: Bool = false,
                       fromDefaultBranch: Bool = false) throws -> String {
        guard let root = Git.repoRoot(of: directory) else {
            throw GitError(description: "\(directory) is not inside a git repository.")
        }
        let path = base.appendingPathComponent(URL(fileURLWithPath: root).lastPathComponent)
            .appendingPathComponent(Self.folderName(for: branch)).path
        try Self.add(branch: branch, from: directory, at: path, copyEnvironmentFiles: copyEnvironmentFiles,
                     fromDefaultBranch: fromDefaultBranch)
        return path
    }

    /// A branch as one folder name, since its slashes would nest folders.
    public static func folderName(for branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }

    /// What a new branch will start from, for the sheets to name before anything runs. Reads only what git already knows, without the network.
    public static func startPoint(in directory: String, fromDefaultBranch: Bool) -> String {
        if fromDefaultBranch {
            if let ref = try? Git.run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: directory) { return ref }
            if (try? Git.run(["remote", "get-url", "origin"], in: directory)) != nil { return "origin's default branch" }
        }
        return Git.branch(of: directory) ?? "the current commit"
    }

    /// The remote's default branch, like `origin/main`, fetched first so a new branch starts from the latest commit.
    /// Nil without an `origin` that names one. An offline fetch still returns the ref as it was last fetched.
    static func latestDefaultBranch(in directory: String) -> String? {
        let head = ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]
        if (try? Git.run(head, in: directory)) == nil {
            // A repo made with `git remote add` rather than cloned has no origin/HEAD until git asks the remote.
            _ = try? Git.run(["remote", "set-head", "origin", "--auto"], in: directory, timeout: 15)
        }
        guard let ref = try? Git.run(head, in: directory), ref.hasPrefix("origin/") else { return nil }
        _ = try? Git.run(["fetch", "--quiet", "--no-tags", "origin", String(ref.dropFirst("origin/".count))],
                         in: directory, timeout: 15)
        return ref
    }

    /// Checks out `branch` of the repo containing `directory` at `path`, creating the branch when it doesn't exist.
    /// A new branch starts from the remote's latest default branch when `fromDefaultBranch` is set and there is one.
    static func add(branch: String, from directory: String, at path: String, copyEnvironmentFiles: Bool,
                    fromDefaultBranch: Bool = false) throws {
        let source = Git.topLevel(of: directory) ?? directory
        guard !FileManager.default.fileExists(atPath: path) else {
            throw GitError(description: "A worktree already exists at \(path).")
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)

        // A worktree folder deleted outside git still holds its branch, and add would refuse it.
        _ = try? Git.run(["worktree", "prune"], in: directory)
        let exists = Git.hasBranch(branch, in: directory)
        if exists {
            try Git.run(["worktree", "add", path, branch], in: directory)
        } else if fromDefaultBranch, let start = latestDefaultBranch(in: directory) {
            // Without --no-track the branch would track origin/main, and a plain push or pull would aim at main.
            try Git.run(["worktree", "add", "--no-track", "-b", branch, path, start], in: directory)
        } else {
            try Git.run(["worktree", "add", "-b", branch, path], in: directory)
        }
        if copyEnvironmentFiles {
            do {
                try inheritEnvironmentFiles(from: source, to: path)
            } catch {
                _ = try? Git.run(["worktree", "remove", "--force", path], in: directory)
                throw error
            }
        }
    }

    /// Copies local environment files so a worktree can run like the checkout it came from.
    private static func inheritEnvironmentFiles(from source: String, to destination: String) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: source), includingPropertiesForKeys: nil)
        for file in files {
            let name = file.lastPathComponent
            guard name == ".env" || name.hasPrefix(".env.") else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  (try? Git.run(["check-ignore", "--quiet", "--", name], in: source)) != nil,
                  (try? Git.run(["check-ignore", "--quiet", "--", name], in: destination)) != nil else { continue }
            let target = URL(fileURLWithPath: destination).appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            try FileManager.default.copyItem(
                at: file.resolvingSymlinksInPath(),
                to: target)
        }
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
        guard !hasUncommittedChanges(path) else {
            throw GitError(description: "\(path) has uncommitted changes.")
        }
        try WorktreeScripts.tearDown(in: path)
        try Git.run(["worktree", "remove", path], in: root)
    }
}
