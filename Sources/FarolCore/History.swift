import Foundation

/// A checkout's commits as a graph, like `git log --graph`, and the branches you can pick to show.
public enum History {
    public struct Commit: Equatable {
        public let hash: String
        public let parents: [String]
        public let author: String
        public let date: Date
        /// Branches and tags pointing here, as git decorates them: "HEAD -> main", "origin/main", "tag: v1".
        public let refs: [String]
        public let subject: String

        public var shortHash: String { String(hash.prefix(7)) }
    }

    /// A line drawn in one half of a row, from lane `from` to lane `to`.
    public struct Edge: Equatable {
        public let from: Int
        public let to: Int
    }

    public struct Row: Equatable {
        public let commit: Commit
        /// The lane the commit's dot sits in.
        public let column: Int
        /// Top edge of the row down to its middle.
        public let top: [Edge]
        /// Middle of the row down to its bottom edge.
        public let bottom: [Edge]
        /// Each branch gets the next color when it starts, so neighbors differ even when a lane is reused.
        /// The commit's color, then each lane's above and below the dot, indexed by lane.
        public var color = 0
        public var colorsAbove: [Int] = []
        public var colorsBelow: [Int] = []
        /// Lanes in use on this row, to size the graph column.
        public var width: Int { ([column] + top.flatMap { [$0.from, $0.to] } + bottom.flatMap { [$0.from, $0.to] }).max()! + 1 }
    }

    /// Big enough for recent work, small enough that git and the layout stay instant on a large repo.
    public static let limit = 400

    /// The commits reachable from `branch`, or from every branch when it is nil, newest first.
    public static func commits(in directory: String, branch: String?, limit: Int = limit) throws -> [Commit] {
        let format = ["%H", "%P", "%an", "%at", "%D", "%s"].joined(separator: "%x1f")
        let output = try Git.run(["log", "--topo-order", "--no-color", "--format=\(format)", "-n", "\(limit)",
                                  branch ?? "--all"], in: directory)
        return parse(output)
    }

    /// Local branches first, then remote ones, each most recently committed first.
    public static func branches(in directory: String) -> (local: [String], remote: [String]) {
        let output = (try? Git.run(["for-each-ref", "--sort=-committerdate", "--format=%(refname)", "refs/heads", "refs/remotes"],
                                   in: directory)) ?? ""
        var local: [String] = [], remote: [String] = []
        for ref in output.split(separator: "\n").map(String.init) {
            if ref.hasPrefix("refs/heads/") {
                local.append(String(ref.dropFirst("refs/heads/".count)))
            } else if ref.hasPrefix("refs/remotes/"), !ref.hasSuffix("/HEAD") {
                // origin/HEAD only points at another remote branch, which is already listed.
                remote.append(String(ref.dropFirst("refs/remotes/".count)))
            }
        }
        return (local, remote)
    }

    /// Checks out `branch`. A remote one switches to the local branch of the same name, made to track it if it doesn't exist yet.
    public static func checkout(_ branch: String, remote: Bool, in directory: String) throws {
        guard remote, let slash = branch.firstIndex(of: "/") else {
            try Git.run(["switch", branch], in: directory)
            return
        }
        let name = String(branch[branch.index(after: slash)...])
        let exists = (try? Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: directory)) != nil
        try Git.run(exists ? ["switch", name] : ["switch", "--track", branch], in: directory)
    }

    /// Checks out a commit. A local branch pointing at it is switched to, so you only land on a detached HEAD when there is none.
    public static func checkout(_ commit: Commit, in directory: String) throws {
        let local = Set(branches(in: directory).local)
        let names = commit.refs.map { $0.hasPrefix("HEAD -> ") ? String($0.dropFirst("HEAD -> ".count)) : $0 }
        if let branch = names.first(where: local.contains) {
            try Git.run(["switch", branch], in: directory)
        } else {
            try Git.run(["switch", "--detach", commit.hash], in: directory)
        }
    }

    /// Creates `name` at `start` and checks it out.
    public static func createBranch(_ name: String, from start: String, in directory: String) throws {
        try Git.run(["switch", "--create", name, start], in: directory)
    }

    /// Git refuses to delete a branch that isn't merged unless `force` is set, so work isn't lost by accident.
    public static func deleteBranch(_ name: String, force: Bool, in directory: String) throws {
        try Git.run(["branch", force ? "-D" : "-d", name], in: directory)
    }

    /// Deletes a branch on its server, like origin/feat. Everyone who fetches loses it too.
    public static func deleteRemoteBranch(_ branch: String, in directory: String) throws {
        guard let slash = branch.firstIndex(of: "/") else { throw GitError(description: "\(branch) isn't a remote branch.") }
        try Git.run(["push", String(branch[..<slash]), "--delete", String(branch[branch.index(after: slash)...])], in: directory)
    }

    /// Replays the checked out branch on top of `base`. On a conflict git stops and says how to go on.
    public static func rebase(onto base: String, in directory: String) throws {
        try Git.run(["rebase", base], in: directory)
    }

    /// Needs an editor, so it runs in a terminal rather than in the background.
    public static func interactiveRebaseCommand(onto base: String) -> String {
        "git rebase --interactive '\(base.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Adds a commit that undoes `commit`, so history stays as it was and a pushed branch needs no force push.
    /// A merge is undone against its first parent, which takes back what the merged branch brought in.
    public static func revert(_ commit: Commit, in directory: String) throws {
        try Git.run(["revert", "--no-edit"] + (commit.parents.count > 1 ? ["-m", "1"] : []) + [commit.hash], in: directory)
    }

    public static func cherryPick(_ commit: Commit, in directory: String) throws {
        try Git.run(["cherry-pick", commit.hash], in: directory)
    }

    /// Commits what the review panel shows as uncommitted: staged, unstaged and untracked files together.
    public static func commitAll(_ message: String, in directory: String) throws {
        try Git.run(["add", "--all"], in: directory)
        try Git.run(["commit", "--message", message], in: directory)
    }

    /// Pushes the checked out branch under its own name and tracks it there. A branch with no remote yet goes to origin.
    public static func push(in directory: String) throws {
        let configured = Git.branch(of: directory).flatMap { try? Git.run(["config", "branch.\($0).remote"], in: directory) }
        // "." means the branch tracks a local one, which is no place to push to.
        let remote = configured.flatMap { $0 == "." || $0.isEmpty ? nil : $0 } ?? "origin"
        try Git.run(["push", "--set-upstream", remote, "HEAD"], in: directory)
    }

    static func parse(_ output: String) -> [Commit] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, let time = TimeInterval(fields[3]) else { return nil }
            return Commit(
                hash: fields[0],
                parents: fields[1].split(separator: " ").map(String.init),
                author: fields[2],
                date: Date(timeIntervalSince1970: time),
                refs: fields[4].isEmpty ? [] : fields[4].components(separatedBy: ", "),
                // A subject can hold the separator itself, so the rest of the line is all subject.
                subject: fields[5...].joined(separator: "\u{1f}"))
        }
    }

    /// Places each commit in a lane and lists the lines that join it to its children above and its parents below.
    /// Commits must be in topological order, children before parents.
    public static func graph(_ commits: [Commit]) -> [Row] {
        // What each lane waits for: the hash of the next commit it leads to, or nil when the lane is free.
        var lanes: [String?] = []
        var colors: [Int] = []
        var next = 0
        func newColor() -> Int {
            defer { next += 1 }
            return next
        }
        var rows: [Row] = []
        for commit in commits {
            let waited = lanes.firstIndex(of: commit.hash)
            let column = waited ?? lanes.firstIndex(of: nil) ?? lanes.count
            if column == lanes.count {
                lanes.append(nil)
                colors.append(0)
            }
            let colorsAbove = colors
            let color = waited.map { colors[$0] } ?? newColor()

            var top: [Edge] = []
            var passing: Set<Int> = []
            for (lane, waiting) in lanes.enumerated() where waiting != nil {
                if waiting == commit.hash {
                    top.append(Edge(from: lane, to: column))
                } else {
                    top.append(Edge(from: lane, to: lane))
                    passing.insert(lane)
                }
            }
            // Children that met here are done. Their lanes are free for what comes next.
            lanes = lanes.map { $0 == commit.hash ? nil : $0 }

            var fromCommit: Set<Int> = []
            for (index, parent) in commit.parents.enumerated() {
                if index == 0 {
                    // Each branch keeps its own lane down to where it forked, even when another lane waits for the same parent.
                    lanes[column] = parent
                    colors[column] = color
                    fromCommit.insert(column)
                } else if let lane = lanes.firstIndex(of: parent) {
                    // Another branch already leads to this parent, so the two lines meet in its lane.
                    fromCommit.insert(lane)
                } else {
                    let lane = lanes.firstIndex(of: nil) ?? lanes.count
                    if lane == lanes.count {
                        lanes.append(nil)
                        colors.append(0)
                    }
                    lanes[lane] = parent
                    colors[lane] = newColor()
                    fromCommit.insert(lane)
                }
            }

            let bottom = passing.sorted().map { Edge(from: $0, to: $0) }
                + fromCommit.sorted().map { Edge(from: column, to: $0) }
            let colorsBelow = colors
            while lanes.last == .some(nil) {
                lanes.removeLast()
                colors.removeLast()
            }

            rows.append(Row(commit: commit, column: column, top: top, bottom: bottom,
                            color: color, colorsAbove: colorsAbove, colorsBelow: colorsBelow))
        }
        return rows
    }
}
