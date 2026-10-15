import Foundation

/// Tasks that span several repos. Each gets one folder, `<base>/<branch>`, with a worktree of every repo in it.
/// They all share the branch, and one agent started in the folder sees them all.
public struct TaskFolders {
    public let base: URL

    public static let `default` = TaskFolders(
        base: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".farol/tasks"))

    public init(base: URL) {
        self.base = base
    }

    /// The git repos right inside `folder`, by name.
    /// Only looks for `.git` without running git, so it stays instant even in a home folder full of projects.
    public static func repos(in folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { (folder as NSString).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0 + "/.git") }
    }

    /// The branch a repo has checked out, read from its HEAD file without running git. Nil when detached.
    public static func branch(of repo: String) -> String? {
        var gitDir = repo + "/.git"
        // A worktree's `.git` is a file that points at its real git folder.
        if let link = try? String(contentsOfFile: gitDir, encoding: .utf8), link.hasPrefix("gitdir: ") {
            let target = link.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = target.hasPrefix("/") ? target : repo + "/" + target
        }
        guard let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8),
              head.hasPrefix("ref: refs/heads/") else { return nil }
        return head.dropFirst("ref: refs/heads/".count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The task folder a path is in, even from inside one of its repos, or nil outside Farol's tasks.
    public func root(of path: String) -> String? {
        let resolved = { (url: URL) in url.resolvingSymlinksInPath().path }
        guard resolved(URL(fileURLWithPath: path)).hasPrefix(resolved(base) + "/") else { return nil }
        return Worktrees.folder(of: path, under: base, depth: 1)
    }

    /// Creates the task folder with a worktree of each repo on `branch`. Either all of them are made or none.
    public func create(branch: String, repos: [String], copyEnvironmentFiles: Bool = false) throws -> String {
        let folder = base.appendingPathComponent(Worktrees.folderName(for: branch))
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw GitError(description: "A task folder already exists at \(folder.path).")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let paths = repos.map { folder.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent).path }
        var errors = [Error?](repeating: nil, count: repos.count)
        let lock = NSLock()
        // Each repo checks out on its own, so big ones don't wait in line.
        DispatchQueue.concurrentPerform(iterations: repos.count) { index in
            do {
                try Worktrees.add(
                    branch: branch, from: repos[index], at: paths[index], copyEnvironmentFiles: copyEnvironmentFiles)
            } catch {
                lock.withLock { errors[index] = error }
            }
        }
        if let failed = errors.firstIndex(where: { $0 != nil }), let error = errors[failed] {
            for (index, path) in paths.enumerated() where errors[index] == nil {
                _ = try? Git.run(["worktree", "remove", "--force", path], in: repos[index])
            }
            try? FileManager.default.removeItem(at: folder)
            let name = URL(fileURLWithPath: repos[failed]).lastPathComponent
            throw GitError(description: "\(name): \(error)")
        }
        return folder.path
    }

    /// Work that removing the task would lose: changes in any of its repos, or files the agent left beside them.
    public func hasUncommittedChanges(_ folder: String) -> Bool {
        contents(of: folder).contains { item in
            guard isWorktree(item) else { return true }
            let status = (try? Git.run(["status", "--porcelain"], in: item)) ?? ""
            return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Removes every worktree in the task folder, then the folder. The branches stay, so no commit is lost.
    /// A worktree git refuses to remove stays, and the others go anyway. The error names each one kept.
    public func remove(_ folder: String) throws {
        guard root(of: folder) == URL(fileURLWithPath: folder).resolvingSymlinksInPath().path else {
            throw GitError(description: "\(folder) is not a Farol task folder.")
        }
        let kept = contents(of: folder).filter(isWorktree).filter { item in
            guard let repo = Git.repoRoot(of: item) else { return true }
            return (try? Git.run(["worktree", "remove", item], in: repo)) == nil
        }
        // Whatever isn't a worktree was left out above, and removing the folder would take it along.
        if contents(of: folder).isEmpty { try FileManager.default.removeItem(atPath: folder) }
        guard kept.isEmpty else {
            let names = kept.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
            throw GitError(description: "Kept \(names.joined(separator: ", ")) in \(folder).")
        }
    }

    /// A worktree has a `.git` file pointing at its repo, where a plain folder has none.
    private func isWorktree(_ path: String) -> Bool {
        var isDirectory: ObjCBool = true
        return FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func contents(of folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0 != ".DS_Store" }
            .map { (folder as NSString).appendingPathComponent($0) }
    }
}
