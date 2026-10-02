import Foundation

/// What changed in a checkout: uncommitted work, or everything since the branch left its base.
public enum Diff {
    public enum Scope: Hashable {
        /// Working tree and index against HEAD, plus untracked files.
        case uncommitted
        /// Working tree against the commit where HEAD left `base`, so committed and uncommitted work together.
        case branch(base: String)
        /// What one commit changed, against its first parent. The working tree plays no part.
        case commit(String)
    }

    public struct Line: Equatable {
        public enum Kind { case context, added, removed }
        public let kind: Kind
        public let text: String
        /// The line's number in the new file. Nil for removed lines.
        public let number: Int?
    }

    public struct Hunk: Equatable {
        public let oldStart: Int
        public let newStart: Int
        public var lines: [Line]
    }

    public struct File: Equatable {
        public enum Status { case modified, added, deleted, renamed }
        public var path: String
        public var oldPath: String?
        public var status = Status.modified
        public var isBinary = false
        public var hunks: [Hunk] = []

        /// Where the first change is in the new file, to open it there. A removal points at the line that follows it.
        public var firstChange: Int {
            guard let hunk = hunks.first else { return 1 }
            var number = hunk.newStart
            for line in hunk.lines {
                if line.kind != .context { return line.number ?? number }
                number = (line.number ?? number) + 1
            }
            return hunk.newStart
        }

        public var added: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
        public var removed: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
    }

    public struct Stat: Equatable {
        public var files = 0
        public var added = 0
        public var removed = 0

        public init(files: Int = 0, added: Int = 0, removed: Int = 0) {
            self.files = files
            self.added = added
            self.removed = removed
        }

        public var isEmpty: Bool { files == 0 }
    }

    // MARK: Git

    /// The branch work gets merged into: what origin/HEAD points to, else a local main or master.
    public static func baseBranch(in directory: String) -> String? {
        if let remote = try? Git.run(["rev-parse", "--abbrev-ref", "origin/HEAD"], in: directory), remote != "origin/HEAD" {
            return remote
        }
        return ["main", "master"].first { (try? Git.run(["rev-parse", "--verify", "--quiet", $0], in: directory)) != nil }
    }

    /// Local branches to compare with, most recently committed first, leaving out the one checked out.
    public static func branches(in directory: String, limit: Int = 15) -> [String] {
        let output = (try? Git.run(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads"],
                                   in: directory)) ?? ""
        let current = Git.branch(of: directory)
        return Array(output.split(separator: "\n").map(String.init).filter { $0 != current }.prefix(limit))
    }

    /// Uncommitted when HEAD is the base branch itself, where "since the branch left" means nothing.
    public static func defaultScope(in directory: String) -> Scope {
        guard let base = baseBranch(in: directory), let branch = Git.branch(of: directory),
              branch != base, "origin/\(branch)" != base else { return .uncommitted }
        return .branch(base: base)
    }

    public static func files(in directory: String, _ scope: Scope) throws -> [File] {
        let output = try Git.run(["-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff", "--find-renames"]
                                 + range(scope, in: directory), in: directory, trimming: false)
        if case .commit = scope { return parse(output) }
        return parse(output) + untracked(in: directory).compactMap { added($0, in: directory) }
    }

    /// Counts only, cheap enough to run after every change the agent makes.
    public static func stat(in directory: String, _ scope: Scope) throws -> Stat {
        let output = try Git.run(["diff", "--numstat", "--find-renames"] + range(scope, in: directory), in: directory)
        var stat = Stat()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 3 else { continue }
            stat.files += 1
            stat.added += Int(parts[0]) ?? 0
            stat.removed += Int(parts[1]) ?? 0
        }
        if case .commit = scope { return stat }
        for path in untracked(in: directory) {
            stat.files += 1
            stat.added += lineCount(path, in: directory)
        }
        return stat
    }

    private static func range(_ scope: Scope, in directory: String) throws -> [String] {
        switch scope {
        case .uncommitted: return ["HEAD"]
        case .branch(let base): return [try Git.run(["merge-base", "HEAD", base], in: directory)]
        case .commit(let hash):
            // The first commit has no parent, so it's compared with an empty tree and every file shows as new.
            let parent = try (try? Git.run(["rev-parse", "--verify", "--quiet", hash + "^1"], in: directory))
                ?? Git.run(["hash-object", "-t", "tree", "/dev/null"], in: directory)
            return [parent, hash]
        }
    }

    /// Capped so a folder full of untracked build output can't stall the panel. The rest still show in git status.
    static let untrackedLimit = 200

    /// The files a commit would take: changed against HEAD or untracked. A renamed file is listed under its new name.
    public static func uncommittedPaths(in directory: String) throws -> [String] {
        let output = try Git.run(["-c", "core.quotePath=false", "diff", "--name-only", "--find-renames", "HEAD"], in: directory)
        return output.split(separator: "\n").map(String.init) + untracked(in: directory)
    }

    private static func untracked(in directory: String) -> [String] {
        let output = (try? Git.run(["-c", "core.quotePath=false", "ls-files", "--others", "--exclude-standard"], in: directory)) ?? ""
        return Array(output.split(separator: "\n").map(String.init).prefix(untrackedLimit))
    }

    private static func text(_ path: String, in directory: String) -> String? {
        guard case .text(let text)? = try? Files.read((directory as NSString).appendingPathComponent(path)) else { return nil }
        return text
    }

    private static func lineCount(_ path: String, in directory: String) -> Int {
        text(path, in: directory).map { lines(of: $0).count } ?? 0
    }

    /// An untracked file, shown as a new file with every line added.
    private static func added(_ path: String, in directory: String) -> File? {
        var file = File(path: path, status: .added)
        guard let text = text(path, in: directory) else {
            file.isBinary = true
            return file
        }
        let lines = lines(of: text).enumerated().map { Line(kind: .added, text: $1, number: $0 + 1) }
        if !lines.isEmpty { file.hunks = [Hunk(oldStart: 0, newStart: 1, lines: lines)] }
        return file
    }

    private static func lines(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: Parsing

    /// Reads `git diff` output. Only what the review needs: paths, status, hunks and line numbers.
    static func parse(_ output: String) -> [File] {
        var files: [File] = []
        var newLine = 0
        func path(_ line: Substring, dropping prefix: String) -> String {
            // Git ends the name with a tab when it contains spaces.
            String(line.dropFirst(prefix.count).split(separator: "\t", omittingEmptySubsequences: false)[0])
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                // "a/x b/x": both halves are equal unless renamed, when the rename lines say which is which.
                let rest = line.dropFirst("diff --git a/".count)
                files.append(File(path: String(rest.prefix((rest.count - 3) / 2))))
            } else if files.isEmpty {
                continue
            } else if line.hasPrefix("new file mode") {
                files[files.count - 1].status = .added
            } else if line.hasPrefix("deleted file mode") {
                files[files.count - 1].status = .deleted
            } else if line.hasPrefix("rename from ") {
                files[files.count - 1].oldPath = path(line, dropping: "rename from ")
                files[files.count - 1].status = .renamed
            } else if line.hasPrefix("rename to ") {
                files[files.count - 1].path = path(line, dropping: "rename to ")
            } else if line.hasPrefix("+++ b/") {
                files[files.count - 1].path = path(line, dropping: "+++ b/")
            } else if line.hasPrefix("--- a/"), files[files.count - 1].status == .deleted {
                files[files.count - 1].path = path(line, dropping: "--- a/")
            } else if line.hasPrefix("Binary files ") {
                files[files.count - 1].isBinary = true
            } else if line.hasPrefix("@@ "), let hunk = hunk(line) {
                files[files.count - 1].hunks.append(hunk)
                newLine = hunk.newStart
            } else if var hunk = files[files.count - 1].hunks.popLast() {
                switch line.first {
                case "+":
                    hunk.lines.append(Line(kind: .added, text: String(line.dropFirst()), number: newLine))
                    newLine += 1
                case "-":
                    hunk.lines.append(Line(kind: .removed, text: String(line.dropFirst()), number: nil))
                case " ":
                    hunk.lines.append(Line(kind: .context, text: String(line.dropFirst()), number: newLine))
                    newLine += 1
                default:
                    // "\ No newline at end of file", or the empty string after the last line.
                    break
                }
                files[files.count - 1].hunks.append(hunk)
            }
        }
        return files
    }

    /// "@@ -12,7 +12,9 @@ func main()" gives old start 12 and new start 12.
    private static func hunk(_ line: Substring) -> Hunk? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3,
              let old = Int(parts[1].dropFirst().split(separator: ",")[0]),
              let new = Int(parts[2].dropFirst().split(separator: ",")[0]) else { return nil }
        return Hunk(oldStart: old, newStart: new, lines: [])
    }
}
