import Foundation

/// A merge, rebase, cherry-pick, revert or `git am` that git stopped on conflicts, and what it takes to finish it.
/// Everything is named from your side: "mine" is the branch you are on, "other" is what comes in.
/// Git swaps its own ours and theirs during a rebase, so this is the one place that knows about it.
public enum Merge {
    public enum Kind: Equatable {
        case merge, rebase, cherryPick, revert
        /// Mailed patches applied with `git am`. Its ours is your branch, like a cherry-pick.
        case am

        /// The word git uses on the command line, which also reads fine in a sentence.
        public var command: String {
            switch self {
            case .merge: "merge"
            case .rebase: "rebase"
            case .cherryPick: "cherry-pick"
            case .revert: "revert"
            case .am: "am"
            }
        }
    }

    public struct Operation: Equatable {
        public let kind: Kind
        /// Which commit of the rebase is being replayed, from 1, and how many there are.
        public var step: Int?
        public var total: Int?
        /// The commit being applied, for a rebase, cherry-pick or revert.
        public var subject: String?
        /// Names for the two sides, like the branch names, for the column headers.
        public var mine: String
        public var other: String

        public var canSkip: Bool { kind != .merge }
    }

    public struct Conflict: Equatable {
        public enum Status: Equatable {
            case bothModified, bothAdded, bothDeleted
            case deletedByMine, deletedByOther
            case addedByMine, addedByOther

            /// Both sides have text to compare, so the three columns can show it.
            public var isTextual: Bool { self == .bothModified || self == .bothAdded }
        }

        /// What a version holds at the path, from its mode in the index.
        public enum Entry: Equatable {
            case file, executable, symlink, submodule

            init?(mode: Substring) {
                switch mode {
                case "100644": self = .file
                case "100755": self = .executable
                case "120000": self = .symlink
                case "160000": self = .submodule
                default: return nil
                }
            }

            public var isFile: Bool { self == .file || self == .executable }
        }

        public let path: String
        public let status: Status
        /// Each version's entry, nil where it has none. Named from your side like the rest.
        public var base: Entry?
        public var mine: Entry?
        public var other: Entry?
        /// Both sides hold the same bytes, so only their modes differ.
        public var sameContent = false

        public init(path: String, status: Status, base: Entry? = nil, mine: Entry? = nil, other: Entry? = nil, sameContent: Bool = false) {
            self.path = path
            self.status = status
            self.base = base
            self.mine = mine
            self.other = other
            self.sameContent = sameContent
        }

        /// Text on both sides, for the three columns.
        /// Git prints a link's target or a submodule's commit as text, but writing that back would replace it with a file.
        public var isTextual: Bool {
            status.isTextual && mine?.isFile == true && other?.isFile == true && !sameContent
        }

        /// Both sides changed whether the file is executable, each its own way, so the result needs one of them.
        public var modeConflict: Bool {
            guard let mine, let other, mine.isFile, other.isFile else { return false }
            return mine != other && base != mine && base != other
        }
    }

    // MARK: Reading

    /// Where git keeps its state for the checkout. For a worktree, that is inside the main repo.
    public static func gitDirectory(of directory: String) -> String? {
        try? Git.run(["rev-parse", "--absolute-git-dir"], in: directory)
    }

    /// The operation in progress in a checkout, or nil when git isn't stopped on anything.
    public static func operation(in directory: String) -> Operation? {
        guard let gitDir = gitDirectory(of: directory) else { return nil }
        let fm = FileManager.default
        func file(_ name: String) -> String? {
            (try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent(name), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let current = Git.branch(of: directory) ?? "HEAD"

        for folder in ["rebase-merge", "rebase-apply"] where fm.fileExists(atPath: (gitDir as NSString).appendingPathComponent(folder)) {
            let merge = folder == "rebase-merge"
            // `git am` keeps its state in the same folder as the apply backend of rebase, and says so with this file.
            if !merge, fm.fileExists(atPath: (gitDir as NSString).appendingPathComponent("rebase-apply/applying")) {
                let step = file("rebase-apply/next").flatMap { Int($0) }
                let patch = step.flatMap { file("rebase-apply/" + String(format: "%04d", $0)) }.map(Self.patch)
                return Operation(
                    kind: .am, step: step, total: file("rebase-apply/last").flatMap { Int($0) },
                    subject: file("rebase-apply/final-commit")?.split(separator: "\n").first.map(String.init) ?? patch?.subject,
                    mine: current, other: patch?.hash ?? "the patch")
            }
            let head = file("\(folder)/head-name").map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
            let onto = file("\(folder)/onto")
            return Operation(
                kind: .rebase,
                step: file(merge ? "\(folder)/msgnum" : "\(folder)/next").flatMap { Int($0) },
                total: file(merge ? "\(folder)/end" : "\(folder)/last").flatMap { Int($0) },
                subject: subject(of: "REBASE_HEAD", in: directory),
                mine: head ?? current,
                other: onto.map { name(of: $0, in: directory) } ?? "upstream")
        }
        if let head = file("MERGE_HEAD")?.split(separator: "\n").first.map(String.init) {
            return Operation(kind: .merge, mine: current, other: mergedName(file("MERGE_MSG")) ?? name(of: head, in: directory))
        }
        if let head = file("CHERRY_PICK_HEAD") {
            return Operation(kind: .cherryPick, subject: subject(of: head, in: directory), mine: current, other: String(head.prefix(7)))
        }
        if let head = file("REVERT_HEAD") {
            return Operation(kind: .revert, subject: subject(of: head, in: directory), mine: current,
                             other: "revert of \(head.prefix(7))")
        }
        return nil
    }

    /// One commit of a rebase, for the row of steps above the files.
    public struct Step: Equatable {
        public enum State: Equatable { case done, current, todo }
        public let hash: String
        public let subject: String
        public let state: State
    }

    /// The commits a rebase replays, from its done and todo lists. The last one done is the one it stopped on.
    /// Lines that run a command or set a label have no commit, so they are left out.
    /// The apply backend and `git am` keep one numbered patch per commit instead, with a counter for the current one.
    public static func rebaseSteps(in directory: String) -> [Step] {
        guard let gitDir = gitDirectory(of: directory) else { return [] }
        let apply = (gitDir as NSString).appendingPathComponent("rebase-apply")
        if FileManager.default.fileExists(atPath: apply) {
            func number(_ name: String) -> Int? {
                (try? String(contentsOfFile: (apply as NSString).appendingPathComponent(name), encoding: .utf8))
                    .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            guard let next = number("next"), let last = number("last"), last >= 1 else { return [] }
            return (1...last).map { index in
                let text = (try? String(contentsOfFile: (apply as NSString).appendingPathComponent(String(format: "%04d", index)),
                                        encoding: .utf8)) ?? ""
                let patch = Self.patch(text)
                return Step(hash: patch.hash ?? "#\(index)", subject: patch.subject ?? "",
                            state: index < next ? .done : index == next ? .current : .todo)
            }
        }
        func read(_ name: String) -> [(hash: String, subject: String)] {
            let path = (gitDir as NSString).appendingPathComponent("rebase-merge/\(name)")
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let commands: Set = ["pick", "p", "reword", "r", "edit", "e", "squash", "s", "fixup", "f", "drop", "d"]
            return text.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: " ")
                // A fixup may carry -C or -c before its commit.
                guard let command = fields.first, commands.contains(String(command)),
                      let at = fields.dropFirst().firstIndex(where: { !$0.hasPrefix("-") }) else { return nil }
                var subject = fields[(at + 1)...]
                if subject.first == "#" { subject = subject.dropFirst() }
                return (String(fields[at].prefix(7)), subject.joined(separator: " "))
            }
        }
        let done = read("done"), todo = read("git-rebase-todo")
        return done.enumerated().map { index, step in
            Step(hash: step.hash, subject: step.subject, state: index == done.count - 1 ? .current : .done)
        } + todo.map { Step(hash: $0.hash, subject: $0.subject, state: .todo) }
    }

    /// The commit a mailed patch came from and its subject, from the "From <hash>" line format-patch starts with and the headers.
    static func patch(_ text: String) -> (hash: String?, subject: String?) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var hash: String?
        if let first = lines.first, first.hasPrefix("From ") {
            let word = first.dropFirst(5).prefix { $0 != " " }
            if word.count >= 40, word.allSatisfy(\.isHexDigit) { hash = String(word.prefix(7)) }
        }
        var subject: String?
        for (index, line) in lines.enumerated() {
            if line.isEmpty { break }
            guard line.hasPrefix("Subject: ") else { continue }
            // A long header goes on over lines that start with a space.
            var text = String(line.dropFirst(9))
            for more in lines[(index + 1)...] {
                guard more.first == " " || more.first == "\t" else { break }
                text += " " + more.trimmingCharacters(in: .whitespaces)
            }
            if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
                text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            subject = text
            break
        }
        return (hash, subject)
    }

    /// Conflicted files git's rerere already resolved the way you did last time.
    /// Git still lists them as conflicts, waiting for you to look, but leaves no markers in them.
    /// Rerere forgets a path once it reuses a resolution, while one you resolve by hand stays in MERGE_RR until the commit.
    public static func reused(_ conflicts: [Conflict], in directory: String) -> Set<String> {
        guard rerereEnabled(in: directory) else { return [] }
        let pending = rerereRecorded(in: directory)
        return Set(conflicts.filter { conflict in
            guard conflict.isTextual, !pending.contains(conflict.path),
                  let text = try? String(contentsOfFile: (directory as NSString).appendingPathComponent(conflict.path), encoding: .utf8)
            else { return false }
            return !text.split(separator: "\n").contains { $0.hasPrefix("<<<<<<< ") }
        }.map(\.path))
    }

    // MARK: Work done outside Farol

    /// Conflicted files changed on disk since git wrote them, by you or an agent, with the conflicts they still mark.
    /// Git's own output is made again and compared with the file, the marker labels aside since they depend on the command.
    /// Files rerere resolved are left to `reused`, which says more about them.
    public static func edited(_ conflicts: [Conflict], skipping: Set<String> = [], in directory: String, _ kind: Kind) -> [String: Int] {
        let textual = conflicts.filter { $0.isTextual && !skipping.contains($0.path) }
        guard !textual.isEmpty else { return [:] }
        let tree = merged(in: directory, kind)?.tree
        var edited: [String: Int] = [:]
        for conflict in textual {
            guard let disk = try? String(contentsOfFile: (directory as NSString).appendingPathComponent(conflict.path), encoding: .utf8)
            else { continue }
            // Git's merge again, when it can be redone from commits. A clean result there means it merged with other options.
            var written = tree.flatMap { try? Git.run(["cat-file", "blob", "\($0):\(conflict.path)"], in: directory, trimming: false) }
            if written.map({ markers(in: $0) == 0 }) ?? true { written = mergeFile(conflict.path, in: directory) }
            guard let written, unlabeled(written) != unlabeled(disk) else { continue }
            edited[conflict.path] = markers(in: disk)
        }
        return edited
    }

    /// Files rerere resolved like last time and staged by itself, as it does with rerere.autoUpdate.
    /// Git no longer lists them, so they come from git's merge redone: in conflict there, not in the index, and not waiting in MERGE_RR.
    /// The conflict must also be the one rerere last reused a resolution for, which it keeps in its cache as "thisimage".
    public static func restagedByRerere(_ conflicts: [Conflict], in directory: String, _ kind: Kind) -> [String] {
        guard rerereEnabled(in: directory),
              (try? Git.run(["config", "--bool", "rerere.autoUpdate"], in: directory)) == "true",
              let merged = merged(in: directory, kind),
              let common = try? Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory)
        else { return [] }
        let cache = (common as NSString).appendingPathComponent("rr-cache")
        let images = Set(((try? FileManager.default.contentsOfDirectory(atPath: cache)) ?? []).compactMap { id in
            try? String(contentsOfFile: "\(cache)/\(id)/thisimage", encoding: .utf8)
        })
        guard !images.isEmpty else { return [] }
        let unmerged = Set(conflicts.map(\.path)), pending = rerereRecorded(in: directory)
        return merged.conflicted.filter { path in
            guard !unmerged.contains(path), !pending.contains(path),
                  let text = try? Git.run(["cat-file", "blob", "\(merged.tree):\(path)"], in: directory, trimming: false)
            else { return false }
            return images.contains(rerereImage(text))
        }
    }

    /// Git's merge for the step it stopped on, done again in memory: the tree it leaves with its markers, and the paths in conflict.
    /// Nil for `git am`, whose patches aren't commits to merge.
    private static func merged(in directory: String, _ kind: Kind) -> (tree: String, conflicted: [String])? {
        guard let gitDir = gitDirectory(of: directory) else { return nil }
        func head(_ name: String) -> String? {
            (try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent(name), encoding: .utf8))?
                .split(separator: "\n").first.map(String.init)
        }
        let commits: [String]
        switch kind {
        case .merge:
            guard let other = head("MERGE_HEAD") else { return nil }
            commits = ["HEAD", other]
        case .rebase, .cherryPick:
            guard let picked = head(kind == .rebase ? "REBASE_HEAD" : "CHERRY_PICK_HEAD") else { return nil }
            commits = ["--merge-base=\(picked)^", "HEAD", picked]
        case .revert:
            guard let reverted = head("REVERT_HEAD") else { return nil }
            commits = ["--merge-base=\(reverted)", "HEAD", "\(reverted)^"]
        case .am:
            return nil
        }
        guard let output = runCountingConflicts(["merge-tree", "--write-tree", "-z", "--name-only", "--no-messages"] + commits,
                                                in: directory)
        else { return nil }
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard let tree = fields.first, !tree.isEmpty else { return nil }
        return (tree, Array(fields.dropFirst().prefix { !$0.isEmpty }))
    }

    /// The three stages merged again with git merge-file, when the merge can't be redone from commits.
    /// The stages are git's own ours and theirs, in the order it wrote them.
    private static func mergeFile(_ path: String, in directory: String) -> String? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("farol-merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        var files: [String] = []
        for (stage, name) in [(2, "ours"), (1, "base"), (3, "theirs")] {
            // Both sides adding the file merge against nothing.
            let text = (try? Git.run(["show", ":\(stage):\(path)"], in: directory, trimming: false)) ?? ""
            let file = folder.appendingPathComponent(name)
            guard (try? Data(text.utf8).write(to: file)) != nil else { return nil }
            files.append(file.path)
        }
        let style = (try? Git.run(["config", "merge.conflictStyle"], in: directory)) ?? ""
        let options = ["diff3": ["--diff3"], "zdiff3": ["--zdiff3"]][style] ?? []
        return runCountingConflicts(["merge-file", "-p"] + options + files, in: directory)
    }

    /// Merge-file and merge-tree exit with the number of conflicts, so only a code from 128 up is a failure.
    private static func runCountingConflicts(_ arguments: [String], in directory: String) -> String? {
        try? Git.run("/bin/sh", ["-c", "/usr/bin/git \"$@\"\n[ $? -lt 128 ]", "git"] + arguments, in: directory, trimming: false)
    }

    /// Lines git starts a conflict with.
    private static func markers(in text: String) -> Int {
        text.split(separator: "\n").filter { isMarker($0, "<") }.count
    }

    private static func isMarker(_ line: Substring, _ character: Character) -> Bool {
        let rest = line.dropFirst(7)
        return line.prefix(7).allSatisfy { $0 == character } && line.count >= 7 && (rest.isEmpty || rest.first == " ")
    }

    /// The text with every conflict marker cut to its seven characters, so git's labels ("HEAD", a branch, a commit) don't count.
    static func unlabeled(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line in
            for character: Character in ["<", "|", "=", ">"] where isMarker(line, character) {
                return Substring(String(repeating: character, count: 7))
            }
            return line
        }.joined(separator: "\n")
    }

    /// A conflicted file the way rerere stores it: labels and the ancestor's part dropped, and the two sides in byte order.
    /// That way the same conflict reads the same whichever side is which.
    static func rerereImage(_ text: String) -> String {
        var out = "", first = "", second = ""
        enum Part { case outside, first, base, second }
        var part = Part.outside
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0) {
            let line = line + "\n"
            if isMarker(line.dropLast(), "<"), part == .outside {
                part = .first
            } else if isMarker(line.dropLast(), "|"), part == .first {
                part = .base
            } else if isMarker(line.dropLast(), "="), part == .first || part == .base {
                part = .second
            } else if isMarker(line.dropLast(), ">"), part == .second {
                let sides = [first, second].sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
                out += "<<<<<<<\n" + sides[0] + "=======\n" + sides[1] + ">>>>>>>\n"
                first = ""
                second = ""
                part = .outside
            } else {
                switch part {
                case .outside: out += line
                case .first: first += line
                case .base: break
                case .second: second += line
                }
            }
        }
        return out
    }

    /// The paths rerere noted a conflict for and has no resolution for yet, as "<id> TAB <path> NUL" in MERGE_RR.
    private static func rerereRecorded(in directory: String) -> Set<String> {
        guard let gitDir = gitDirectory(of: directory),
              let text = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("MERGE_RR"), encoding: .utf8)
        else { return [] }
        return Set(text.split(separator: "\0").compactMap { entry in
            entry.firstIndex(of: "\t").map { String(entry[entry.index(after: $0)...]) }
        })
    }

    /// Git turns rerere on by itself once its cache folder exists, unless the setting says no.
    private static func rerereEnabled(in directory: String) -> Bool {
        if let setting = try? Git.run(["config", "--bool", "rerere.enabled"], in: directory) { return setting == "true" }
        guard let gitDir = gitDirectory(of: directory) else { return false }
        let common = (try? Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory)) ?? gitDir
        return FileManager.default.fileExists(atPath: (common as NSString).appendingPathComponent("rr-cache"))
    }

    /// The files git left unmerged, in the order git lists them.
    public static func conflicts(in directory: String, _ kind: Kind) -> [Conflict] {
        let output = (try? Git.run(["-c", "core.quotePath=false", "status", "--porcelain=v2"], in: directory)) ?? ""
        return parseStatus(output, kind)
    }

    /// Reads "u UU N... 100644 100644 100644 100644 h1 h2 h3 path" lines. The path is last and may hold spaces.
    /// The modes are the ancestor's, git's ours, git's theirs and the file on disk, then the three object ids.
    /// Every XY git prints for an unmerged path has a status here, so no conflict is left out of the list.
    static func parseStatus(_ output: String, _ kind: Kind) -> [Conflict] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
            guard fields.count == 11, fields[0] == "u" else { return nil }
            // Git's "us" is the stage 2 side, which is the other branch during a rebase.
            let swapped = kind == .rebase
            let status: Conflict.Status
            switch fields[1] {
            case "UU": status = .bothModified
            case "AA": status = .bothAdded
            case "DD": status = .bothDeleted
            case "DU": status = swapped ? .deletedByOther : .deletedByMine
            case "UD": status = swapped ? .deletedByMine : .deletedByOther
            case "AU": status = swapped ? .addedByOther : .addedByMine
            case "UA": status = swapped ? .addedByMine : .addedByOther
            default: return nil
            }
            let ours = Conflict.Entry(mode: fields[4]), theirs = Conflict.Entry(mode: fields[5])
            let same = fields[8] == fields[9] && fields[8].contains { $0 != "0" }
            return Conflict(path: String(fields[10]), status: status, base: Conflict.Entry(mode: fields[3]),
                            mine: swapped ? theirs : ours, other: swapped ? ours : theirs, sameContent: same)
        }
    }

    public struct Versions: Equatable {
        public var base: String?
        public var mine: String?
        public var other: String?

        public init(base: String? = nil, mine: String? = nil, other: String? = nil) {
            self.base = base
            self.mine = mine
            self.other = other
        }
    }

    /// The common ancestor and both sides of a file, from the index. A side that deleted the file is nil.
    public static func versions(of path: String, in directory: String, _ kind: Kind) -> Versions {
        // A submodule's stages are commits of another repo that git show can't print, so they read the way git diff shows them.
        let submodule = submoduleStages(of: path, in: directory)
        func stage(_ number: Int) -> String? {
            if let commit = submodule[number] { return "Subproject commit \(commit)\n" }
            return try? Git.run(["show", ":\(number):\(path)"], in: directory, trimming: false)
        }
        let swapped = kind == .rebase
        return Versions(base: stage(1), mine: stage(swapped ? 3 : 2), other: stage(swapped ? 2 : 3))
    }

    /// The commit each stage of a conflicted submodule points at, by stage number. Empty for anything else.
    private static func submoduleStages(of path: String, in directory: String) -> [Int: String] {
        let output = (try? Git.run(["--literal-pathspecs", "ls-files", "--stage", "--unmerged", "--", path], in: directory)) ?? ""
        var stages: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            // "160000 <commit> <stage> TAB <path>"
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count == 3, fields[0] == "160000", let stage = fields[2].first?.wholeNumberValue else { continue }
            stages[stage] = String(fields[1])
        }
        return stages
    }

    private static func subject(of commit: String, in directory: String) -> String? {
        try? Git.run(["log", "-1", "--format=%s", commit], in: directory)
    }

    /// A branch pointing at the commit, local ones first, else its short hash.
    private static func name(of commit: String, in directory: String) -> String {
        let refs = (try? Git.run(["for-each-ref", "--points-at", commit, "--format=%(refname:short)", "refs/heads", "refs/remotes"],
                                 in: directory)) ?? ""
        return refs.split(separator: "\n").first.map(String.init) ?? String(commit.prefix(7))
    }

    /// "Merge branch 'main' into feat" names the branch better than its commit does.
    static func mergedName(_ message: String?) -> String? {
        guard let line = message?.split(separator: "\n").first, let open = line.firstIndex(of: "'") else { return nil }
        let rest = line[line.index(after: open)...]
        guard let close = rest.firstIndex(of: "'") else { return nil }
        let name = rest[..<close]
        return name.isEmpty ? nil : String(name)
    }

    /// What a whole-file choice leaves, as a diff against the common ancestor, so you can read the result before you pick.
    /// Nil `result` means the file is deleted. The whole file is one hunk, so the preview reads as the file itself.
    public static func preview(_ path: String, from base: String?, to result: String?) -> Diff.File {
        var file = Diff.File(path: path)
        let old = ThreeWay.lines(of: base ?? "").lines
        guard let result else {
            file.status = .deleted
            let lines = old.map { Diff.Line(kind: .removed, text: $0, number: nil) }
            if !lines.isEmpty { file.hunks = [Diff.Hunk(oldStart: 1, newStart: 0, lines: lines)] }
            return file
        }
        if base == nil { file.status = .added }
        let new = ThreeWay.lines(of: result).lines
        var lines: [Diff.Line] = []
        var i = 0, j = 0
        func context(upTo end: Int) {
            while i < end {
                lines.append(Diff.Line(kind: .context, text: old[i], number: j + 1))
                i += 1
                j += 1
            }
        }
        for hunk in ThreeWay.hunks(old, new) {
            context(upTo: hunk.base.lowerBound)
            lines += old[hunk.base].map { Diff.Line(kind: .removed, text: $0, number: nil) }
            lines += hunk.new.map { Diff.Line(kind: .added, text: new[$0], number: $0 + 1) }
            i = hunk.base.upperBound
            j = hunk.new.upperBound
        }
        context(upTo: old.count)
        if !lines.isEmpty { file.hunks = [Diff.Hunk(oldStart: 1, newStart: 1, lines: lines)] }
        return file
    }

    /// A file once resolved: what it now holds, against HEAD, which is the branch the commit is applied on.
    public static func resolvedPreview(_ path: String, in directory: String) -> Diff.File {
        let head = try? Git.run(["show", "HEAD:\(path)"], in: directory, trimming: false)
        let current = try? String(contentsOfFile: (directory as NSString).appendingPathComponent(path), encoding: .utf8)
        return preview(path, from: head, to: current)
    }

    // MARK: Checks

    public struct Undeclared: Equatable {
        public let name: String
        /// The first line of the result that still uses it, from 1.
        public let line: Int
    }

    /// Names some version declared that the result no longer declares but still uses.
    /// Like a constant one side renamed while the other side added a new use of it.
    /// A hint for what git merged without a conflict, not a compiler. See `CodeNames` for what it leaves out.
    public static func undeclared(in result: String, versions: [String?]) -> [Undeclared] {
        let lines = CodeNames.code(result)
        let kept = Set(CodeNames.bindings(lines, loose: true))
        var seen = Set<String>()
        var found: [Undeclared] = []
        for name in versions.compactMap({ $0 }).flatMap({ CodeNames.bindings(CodeNames.code($0), loose: false) })
        where !kept.contains(name) && !CodeNames.keywords.contains(name) && seen.insert(name).inserted {
            if let index = lines.firstIndex(where: { CodeNames.uses(name, in: $0) }) {
                found.append(Undeclared(name: name, line: index + 1))
            }
        }
        return found.sorted { $0.line < $1.line }
    }

    /// The project's test command, guessed from the files at the top of the checkout. Nil when nothing says.
    public static func testCommand(in directory: String) -> String? {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: (directory as NSString).appendingPathComponent(name)) }
        func read(_ name: String) -> String? {
            try? String(contentsOfFile: (directory as NSString).appendingPathComponent(name), encoding: .utf8)
        }
        if let makefile = read("Makefile") ?? read("makefile"),
           makefile.split(separator: "\n").contains(where: { $0.hasPrefix("test:") || $0.hasPrefix("test :") }) {
            return "make test"
        }
        if let package = read("package.json"),
           let json = try? JSONSerialization.jsonObject(with: Data(package.utf8)) as? [String: Any],
           (json["scripts"] as? [String: Any])?["test"] != nil {
            if has("pnpm-lock.yaml") { return "pnpm test" }
            if has("yarn.lock") { return "yarn test" }
            if has("bun.lockb") || has("bun.lock") { return "bun test" }
            return "npm test"
        }
        if has("Cargo.toml") { return "cargo test" }
        if has("go.mod") { return "go test ./..." }
        if has("Package.swift") { return "swift test" }
        if has("pyproject.toml") || has("pytest.ini") || has("setup.py") { return "pytest" }
        if has("gradlew") { return "./gradlew test" }
        if has("pom.xml") { return "mvn test" }
        return nil
    }

    // MARK: Resolving

    /// Writes the resolved text in place, so the file keeps its permissions, then marks it resolved.
    /// `executable` settles a mode both sides changed. Nil keeps the mode git left on disk.
    public static func resolve(_ path: String, with text: String, executable: Bool? = nil, in directory: String) throws {
        let file = (directory as NSString).appendingPathComponent(path)
        try Data(text.utf8).write(to: URL(fileURLWithPath: file))
        if let executable {
            let fm = FileManager.default
            let mode = (try fm.attributesOfItem(atPath: file)[.posixPermissions] as? Int) ?? 0o644
            try fm.setAttributes([.posixPermissions: executable ? mode | 0o111 : mode & ~0o111], ofItemAtPath: file)
        }
        try Git.run(["add", "--", path], in: directory)
    }

    /// For a file one side deleted: keep it as the other side left it.
    public static func keep(_ path: String, in directory: String) throws {
        try Git.run(["add", "--", path], in: directory)
    }

    public static func delete(_ path: String, in directory: String) throws {
        try Git.run(["rm", "--quiet", "--", path], in: directory)
    }

    /// Takes one side whole, as for a binary file, a link or a submodule. The side's mode comes with it.
    public static func take(mine: Bool, _ path: String, in directory: String, _ kind: Kind) throws {
        let ours = mine != (kind == .rebase)
        if let commit = submoduleStages(of: path, in: directory)[ours ? 2 : 3] {
            // Checkout leaves a submodule alone, so its entry is set straight. Its folder follows when the commit is there already.
            try Git.run(["update-index", "--cacheinfo", "160000,\(commit),\(path)"], in: directory)
            _ = try? Git.run(["--literal-pathspecs", "submodule", "update", "--no-fetch", "--", path], in: directory)
            return
        }
        try Git.run(["checkout", ours ? "--ours" : "--theirs", "--", path], in: directory)
        try Git.run(["add", "--", path], in: directory)
    }

    /// Puts a resolved file back in conflict, from what git saved when it was marked resolved.
    /// Only until the commit is made: after Continue there is nothing left to reopen.
    public static func reopen(_ path: String, in directory: String) throws {
        try Git.run(["update-index", "--unresolve", "--", path], in: directory)
        // The markers go back in the file as git left it. A side that deleted the file has nothing to merge, so this may fail.
        _ = try? Git.run(["checkout", "--merge", "--", path], in: directory)
    }

    /// The message git prepared for the commit Continue makes, without its # lines: the merge's, or the replayed commit's.
    public static func message(in directory: String) -> String? {
        guard let gitDir = gitDirectory(of: directory) else { return nil }
        for name in ["MERGE_MSG", "rebase-merge/message", "rebase-apply/final-commit"] {
            guard let text = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent(name), encoding: .utf8) else { continue }
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("#") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Goes on once every file is resolved, with git's prepared message unless you wrote one.
    /// No editor opens since nobody could type in it, so a message of yours is copied over the one git hands its editor.
    public static func proceed(_ kind: Kind, message: String? = nil, in directory: String) throws {
        guard let message else { return try runWithoutEditor([kind.command, "--continue"], in: directory) }
        // `git am` and the apply backend of rebase never open an editor. They commit with this file, so it is the one to change.
        if let gitDir = gitDirectory(of: directory),
           FileManager.default.fileExists(atPath: (gitDir as NSString).appendingPathComponent("rebase-apply")) {
            try (message + "\n").write(toFile: (gitDir as NSString).appendingPathComponent("rebase-apply/final-commit"),
                                        atomically: true, encoding: .utf8)
            return try runWithoutEditor([kind.command, "--continue"], in: directory)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("farol-message-\(UUID().uuidString)")
        try (message + "\n").write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        // Git runs the editor through the shell with the file to edit appended, so cp overwrites it.
        let quoted = "'" + file.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try Git.run("/usr/bin/env", ["GIT_EDITOR=cp \(quoted)", "/usr/bin/git", kind.command, "--continue"], in: directory)
    }

    /// Leaves the commit being replayed out and goes on with the next one.
    public static func skip(_ kind: Kind, in directory: String) throws {
        try runWithoutEditor([kind.command, "--skip"], in: directory)
    }

    /// Puts everything back as it was before the operation started.
    public static func abort(_ kind: Kind, in directory: String) throws {
        try Git.run([kind.command, "--abort"], in: directory)
    }

    /// GIT_EDITOR wins over git's own setting, so it is set here and not with -c core.editor.
    private static func runWithoutEditor(_ arguments: [String], in directory: String) throws {
        try Git.run("/usr/bin/env", ["GIT_EDITOR=true", "/usr/bin/git"] + arguments, in: directory)
    }
}

/// The three versions of a conflicted file, cut into the places where they differ.
/// Each chunk says which side changed the ancestor there: one of them, both the same way, or both differently.
public struct ThreeWay: Equatable {
    public enum Kind: Equatable {
        /// Only your side changed these lines.
        case mine
        /// Only the incoming side changed them.
        case other
        /// Both sides made the same change.
        case same
        /// Both sides changed them, each its own way.
        case conflict
    }

    public struct Chunk: Equatable {
        public let kind: Kind
        /// Line ranges in each version. An empty range is where lines were added.
        public let base: Range<Int>
        public let mine: Range<Int>
        public let other: Range<Int>
    }

    public let base: [String]
    public let mine: [String]
    public let other: [String]
    public let chunks: [Chunk]
    /// Whether the file ends with a newline, taken from your side, so resolving doesn't add or drop one.
    public let trailingNewline: Bool

    /// `ignoringWhitespace` settles conflicts where a side only changed spacing, indentation or line breaks. See `relaxed`.
    public init(base: String, mine: String, other: String, ignoringWhitespace: Bool = false) {
        let b = Self.lines(of: base), m = Self.lines(of: mine), o = Self.lines(of: other)
        self.base = b.lines
        self.mine = m.lines
        self.other = o.lines
        trailingNewline = mine.isEmpty ? o.trailingNewline : m.trailingNewline
        let chunks = Self.merge(base: b.lines, mine: m.lines, other: o.lines)
        self.chunks = ignoringWhitespace ? chunks.map { Self.relaxed($0, base: b.lines, mine: m.lines, other: o.lines) } : chunks
    }

    /// A conflict read with whitespace ignored. When one side only reformatted the ancestor, the other side's change is taken as is.
    /// When both made the same change, formatted differently, it counts as made alike, with your text.
    /// When both only reformatted, yours is taken too. Chunks stay where they are, so nothing else changes.
    static func relaxed(_ chunk: Chunk, base: [String], mine: [String], other: [String]) -> Chunk {
        guard chunk.kind == .conflict else { return chunk }
        func squeezed(_ lines: ArraySlice<String>) -> String {
            lines.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let b = squeezed(base[chunk.base]), m = squeezed(mine[chunk.mine]), o = squeezed(other[chunk.other])
        let kind: Kind
        if o == b {
            kind = .mine
        } else if m == b {
            kind = .other
        } else if m == o {
            kind = .same
        } else {
            return chunk
        }
        return Chunk(kind: kind, base: chunk.base, mine: chunk.mine, other: chunk.other)
    }

    public func lines(_ chunk: Chunk, mine side: Bool) -> [String] {
        Array(side ? mine[chunk.mine] : other[chunk.other])
    }

    public func baseLines(_ chunk: Chunk) -> [String] { Array(base[chunk.base]) }

    public enum Piece: Equatable {
        /// Lines all three versions share.
        case stable([String])
        /// What the result shows for a chunk at first.
        case chunk(Int, [String])
    }

    /// The result to start from: changes only one side made, or both made alike, are taken, and conflicts show the ancestor.
    /// That is what git already did to the file on disk, without the conflict markers.
    public func start(applying: Bool = true) -> [Piece] {
        var pieces: [Piece] = []
        var at = 0
        for (index, chunk) in chunks.enumerated() {
            if chunk.base.lowerBound > at { pieces.append(.stable(Array(base[at..<chunk.base.lowerBound]))) }
            let lines: [String]
            switch chunk.kind {
            case .mine where applying, .same where applying: lines = self.lines(chunk, mine: true)
            case .other where applying: lines = self.lines(chunk, mine: false)
            default: lines = baseLines(chunk)
            }
            pieces.append(.chunk(index, lines))
            at = chunk.base.upperBound
        }
        if at < base.count { pieces.append(.stable(Array(base[at...]))) }
        return pieces
    }

    /// Joins lines back into a file.
    public func text(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    static func lines(of text: String) -> (lines: [String], trailingNewline: Bool) {
        guard !text.isEmpty else { return ([], false) }
        var lines = text.components(separatedBy: "\n")
        let trailing = lines.last == ""
        if trailing { lines.removeLast() }
        return (lines, trailing)
    }

    /// A stretch of the ancestor one side replaced.
    struct Hunk: Equatable {
        let base: Range<Int>
        let new: Range<Int>
    }

    /// Where `new` differs from `base`, as git's diff would cut it.
    static func hunks(_ base: [String], _ new: [String]) -> [Hunk] {
        let difference = new.difference(from: base)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        while i < base.count || j < new.count {
            if i < base.count, j < new.count, !removed.contains(i), !inserted.contains(j) {
                i += 1
                j += 1
                continue
            }
            let (bi, nj) = (i, j)
            while i < base.count, removed.contains(i) { i += 1 }
            while j < new.count, inserted.contains(j) { j += 1 }
            hunks.append(Hunk(base: bi..<i, new: nj..<j))
        }
        return hunks
    }

    /// The diff3 way: changes from both sides that overlap or touch in the ancestor are one chunk.
    static func merge(base: [String], mine: [String], other: [String]) -> [Chunk] {
        let a = hunks(base, mine), b = hunks(base, other)
        var chunks: [Chunk] = []
        var ia = 0, ib = 0
        // How far each side's line numbers have drifted from the ancestor's before the current chunk.
        var shiftA = 0, shiftB = 0
        while ia < a.count || ib < b.count {
            var groupA: [Hunk] = [], groupB: [Hunk] = []
            if ib >= b.count || (ia < a.count && a[ia].base.lowerBound <= b[ib].base.lowerBound) {
                groupA.append(a[ia])
                ia += 1
            } else {
                groupB.append(b[ib])
                ib += 1
            }
            let low = (groupA.first ?? groupB[0]).base.lowerBound
            var high = (groupA.first ?? groupB[0]).base.upperBound
            // A hunk pulled in can reach the next one on the other side, so this goes on until nothing touches.
            while true {
                if ia < a.count, a[ia].base.lowerBound <= high {
                    groupA.append(a[ia])
                    high = max(high, a[ia].base.upperBound)
                    ia += 1
                } else if ib < b.count, b[ib].base.lowerBound <= high {
                    groupB.append(b[ib])
                    high = max(high, b[ib].base.upperBound)
                    ib += 1
                } else {
                    break
                }
            }
            let deltaA = groupA.reduce(0) { $0 + $1.new.count - $1.base.count }
            let deltaB = groupB.reduce(0) { $0 + $1.new.count - $1.base.count }
            let mineRange = (low + shiftA)..<(high + shiftA + deltaA)
            let otherRange = (low + shiftB)..<(high + shiftB + deltaB)
            let kind: Kind
            if groupB.isEmpty {
                kind = .mine
            } else if groupA.isEmpty {
                kind = .other
            } else {
                kind = mine[mineRange] == other[otherRange] ? .same : .conflict
            }
            chunks.append(Chunk(kind: kind, base: low..<high, mine: mineRange, other: otherRange))
            shiftA += deltaA
            shiftB += deltaB
        }
        return chunks
    }
}

/// Just enough reading of source code, in most languages, to tell where a name is declared and where it is used.
/// Without a parser it guesses, so it leans one way: a version's declarations are the plain ones (`const DELAY`, `func flush`, imports).
/// The result gets credit for anything that may bind a name, like parameters, destructuring and loop variables.
enum CodeNames {
    /// The text's lines with strings and comments blanked out. A string's interpolations stay, since they are code.
    static func code(_ text: String) -> [String] {
        enum State {
            case code(open: Character?, close: Character?, depth: Int)
            case string(end: [Character], interpolates: Bool)
        }
        let chars = Array(text)
        var out = ""
        var stack = [State.code(open: nil, close: nil, depth: 0)]
        var i = 0
        func next(_ offset: Int = 1) -> Character? { i + offset < chars.count ? chars[i + offset] : nil }
        func starts(_ word: [Character]) -> Bool { i + word.count <= chars.count && Array(chars[i..<(i + word.count)]) == word }
        while i < chars.count {
            let c = chars[i]
            switch stack[stack.count - 1] {
            case .code(let open, let close, let depth):
                if c == "/", next() == "/" || (c == "#" && [" ", "\t", "\n", "#", "!", nil].contains(next())) {
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                if c == "/", next() == "*" {
                    i += 2
                    while i < chars.count, !(chars[i] == "*" && next() == "/") {
                        if chars[i] == "\n" { out.append("\n") }
                        i += 1
                    }
                    i += 2
                    continue
                }
                if c == "\"" || c == "`" || (c == "'" && !isLifetime(chars, i)) {
                    let triple = c != "`" && next() == c && next(2) == c
                    stack.append(.string(end: triple ? [c, c, c] : [c], interpolates: c != "'"))
                    out.append(" ")
                    i += triple ? 3 : 1
                    continue
                }
                if let open, let close {
                    if c == close, depth == 0 {
                        stack.removeLast()
                        out.append(" ")
                        i += 1
                        continue
                    }
                    if c == open { stack[stack.count - 1] = .code(open: open, close: close, depth: depth + 1) }
                    if c == close { stack[stack.count - 1] = .code(open: open, close: close, depth: depth - 1) }
                }
                out.append(c)
                i += 1
            case .string(let end, let interpolates):
                if c == "\\", interpolates, next() == "(" {
                    stack.append(.code(open: "(", close: ")", depth: 0))
                    i += 2
                } else if c == "$", interpolates, next() == "{" {
                    stack.append(.code(open: "{", close: "}", depth: 0))
                    i += 2
                } else if c == "\\" {
                    if next() == "\n" { out.append("\n") }
                    i += 2
                } else if starts(end) {
                    stack.removeLast()
                    i += end.count
                } else {
                    // A quote left open ends with its line, unless it can span lines.
                    if c == "\n" {
                        out.append("\n")
                        if end.count == 1, end[0] != "`" { stack.removeLast() }
                    }
                    i += 1
                }
            }
        }
        return out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Rust's `'a` in `<'a>` or `&'a str` is a lifetime, not the start of a character.
    private static func isLifetime(_ chars: [Character], _ i: Int) -> Bool {
        if i > 0, chars[i - 1] == "<" || chars[i - 1] == "&" { return true }
        var j = i + 1
        while j < chars.count, isIdentifier(chars[j]) { j += 1 }
        return j > i + 1 && j < chars.count && chars[j] == ">"
    }

    static func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static let name = #"[A-Za-z_$][\w$]*"#
    private static let modifiers = #"(?:(?:export|default|public|private|protected|internal|fileprivate|open|static|final|override|"#
        + #"async|declare|abstract|pub(?:\([\w ]+\))?|data|sealed|inline|unsafe|lazy|nonisolated|mutating|@[\w.]+(?:\([^)]*\))?|"#
        + #"class(?=\s+(?:func|var|let)))\s+)*"#
    private static let keyword = #"(?:const|let|var|val|func|function\*?|def|class|struct|enum|interface|type|fn|fun|protocol|trait|"#
        + #"typealias|actor|object|mod)"#

    /// `const DELAY`, `public static func flush`, `let mut count`.
    private static let declaration = regex(#"^\s*"# + modifiers + keyword + #"\s+(?:mut\s+)?("# + name + ")")
    /// `const { a, b } =`, `let (x, y) =`, `val (a, b) =`.
    private static let destructuring = regex(#"^\s*(?:export\s+)?(?:const|let|var|val)\s+(?:mut\s+)?[\[{(]([^=]*?)[\]})]\s*[:=]"#)
    /// `import { a, b as c } from "x"`, `import x from "x"`, `import * as ns from "x"`.
    private static let jsImport = regex(#"^\s*import\s+(?:type\s+)?(.+?)\s+from\b"#)
    /// `from x import a, b as c`.
    private static let pythonImport = regex(#"^\s*from\s+\S+\s+import\s+(.+)"#)
    /// `use a::b::{c, d as e}`.
    private static let rustUse = regex(#"^\s*(?:pub\s+)?use\s+(.+)"#)
    /// `import os`, `import a.b.Queue`, `import x as y`.
    private static let bareImport = regex(#"^\s*import\s+(?:static\s+)?([\w.]+)(?:\s+as\s+("# + name + "))?")

    private static let anyDeclaration = regex(#"(?:^|[^\w$.])"# + keyword + #"\s+(?:mut\s+)?("# + name + ")")
    private static let anyDestructuring = regex(#"\b(?:const|let|var|val)\s+(?:mut\s+)?[\[{(]([^=]*)[\]})]"#)
    private static let importLine = regex(#"^\s*(?:import|from|use|using|require|include|#\s*include|extern\s+crate|package)\b"#)
    private static let assignment = regex(#"^\s*("# + name + #"(?:\s*,\s*"# + name + #")*)\s*(?::\s*[^=]+)?(?::=|=(?![=>]))"#)
    private static let loop = regex(#"\bfor\s+\(?\s*(?:const|let|var|val|case)?\s*([\w$\s,]+?)\)?\s*(?:\bin\b|\bof\b|:=)"#)
    private static let functionLine = regex(#"\b(?:func|function|def|fn|fun|init|constructor|subscript)\b"#)
    private static let parentheses = regex(#"\(([^()]*)\)"#)
    private static let lambda = regex(#"\blambda\s+([^:]*):"#)
    /// `push(change) {` in a class, and `catch (e) {`.
    private static let method = regex(#"^\s*(?:(?:async|static|get|set|public|private|protected|override|readonly)\s+)*("#
        + name + #")\s*\(([^()]*)\)\s*(?::[^{]*)?\{"#)
    private static let arrow = regex(#"\(([^()]*)\)\s*(?::[^=]*)?=>|("# + name + #")\s*=>"#)
    /// `{ x in`, `{ (a, b) in` in Swift, `{ a, b ->` in Kotlin, `|a, b|` in Rust.
    private static let closure = regex(#"\{\s*\(?([\w$\s,:]+?)\)?\s+in\b|\{\s*([\w$\s,:]+?)\s*->|\|([^|]*)\|"#)
    private static let alias = regex(#"\bas\s+("# + name + ")")
    private static let member = regex(#"^\s*(?:(?:public|private|protected|readonly|static|override|declare)\s+)+("# + name + ")")
    private static let identifier = regex(name)

    /// Words that look like names but aren't, so they are never reported.
    static let keywords: Set<String> = [
        "abstract", "actor", "and", "as", "async", "await", "break", "case", "catch", "class", "const", "constructor", "continue",
        "crate", "data", "def", "default", "defer", "do", "else", "enum", "export", "extends", "extension", "false", "final", "fn",
        "for", "from", "fun", "func", "function", "get", "go", "guard", "if", "impl", "import", "in", "init", "interface",
        "internal", "is", "lambda", "let", "match", "mod", "mut", "new", "nil", "None", "not", "null", "object", "of", "open",
        "or", "override", "package", "pass", "private", "protocol", "pub", "public", "return", "sealed", "self", "Self", "set",
        "static", "struct", "super", "switch", "this", "throw", "throws", "trait", "True", "False", "true", "try", "type",
        "typealias", "use", "val", "var", "where", "while", "with", "yield",
    ]

    /// The names a text's lines declare. `loose` adds everything that may bind a name, for the result.
    static func bindings(_ lines: [String], loose: Bool) -> [String] {
        var names: [String] = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            func groups(_ regex: NSRegularExpression, all: Bool = false) -> [String] {
                let matches = all ? regex.matches(in: line, range: range) : regex.firstMatch(in: line, range: range).map { [$0] } ?? []
                return matches.flatMap { match in
                    (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
                }
            }
            names += groups(declaration)
            names += groups(destructuring).flatMap { identifiers($0, skippingKeys: true) }
            names += (groups(jsImport) + groups(pythonImport) + groups(rustUse)).flatMap(imported)
            if let path = groups(bareImport).first {
                let parts = path.split(separator: ".")
                // `import a.b.Queue` binds Queue in Kotlin or Java, but `import os.path` binds os in Python, so only a type counts.
                if let last = parts.last, parts.count == 1 || last.first?.isUppercase == true { names.append(String(last)) }
                names += groups(bareImport).dropFirst()
            }
            guard loose else { continue }
            names += groups(anyDeclaration, all: true)
            names += groups(anyDestructuring, all: true).flatMap { identifiers($0) }
            func matches(_ regex: NSRegularExpression) -> Bool { regex.firstMatch(in: line, range: range) != nil }
            if matches(importLine) { names += identifiers(line) }
            names += (groups(assignment) + groups(loop, all: true)).flatMap { identifiers($0) }
            if matches(functionLine) { names += groups(parentheses, all: true).flatMap(parameters) }
            names += groups(lambda).flatMap(parameters)
            let method = groups(method)
            if let first = method.first, !["if", "for", "while", "switch", "with", "return", "function"].contains(first) {
                names += [first] + method.dropFirst().flatMap(parameters)
            }
            names += groups(arrow, all: true).flatMap(parameters)
            names += groups(closure, all: true).flatMap(parameters)
            names += groups(alias, all: true) + groups(member)
        }
        return names
    }

    private static func identifiers(_ text: String, skippingKeys: Bool = false) -> [String] {
        identifier.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            // In `{ a: b }` the name bound is b, and a is the property it comes from.
            if skippingKeys, text[range.upperBound...].first(where: { $0 != " " }) == ":" { return nil }
            return String(text[range])
        }
    }

    /// The names an import clause binds: not the ones renamed with `as`, nor the path a name comes from.
    private static func imported(_ clause: String) -> [String] {
        let words = identifier.matches(in: clause, range: NSRange(clause.startIndex..., in: clause))
            .compactMap { Range($0.range, in: clause) }
        return words.enumerated().compactMap { index, range in
            let word = String(clause[range])
            let after = clause[range.upperBound...].drop { $0 == " " }
            if ["type", "as", "self", "super", "crate", "typeof"].contains(word) || after.hasPrefix("::") || after.hasPrefix(".") {
                return nil
            }
            if index + 1 < words.count, clause[words[index + 1]] == "as" { return nil }
            return word
        }
    }

    /// The names in a parameter list: each one's part before its type or default value.
    private static func parameters(_ list: String) -> [String] {
        list.split(separator: ",").flatMap { part in
            identifiers(String(part.prefix { $0 != ":" && $0 != "=" }))
        }
    }

    /// Whether a line of code uses the name on its own: not as a member after a dot or `::`.
    /// Nor as an argument label or object key, like `delay:` in `f(delay: 1)`.
    static func uses(_ name: String, in line: String) -> Bool {
        let chars = Array(line), word = Array(name)
        guard chars.count >= word.count else { return false }
        for start in 0...(chars.count - word.count) where Array(chars[start..<(start + word.count)]) == word {
            let end = start + word.count
            if start > 0, isIdentifier(chars[start - 1]) { continue }
            if end < chars.count, isIdentifier(chars[end]) { continue }
            if start > 0, chars[start - 1] == "." || chars[start - 1] == ":" {
                // `...rest` and `0..<count` still use the name.
                let spread = start > 1 && chars[start - 2] == "." && chars[start - 1] == "."
                let path = start > 1 && chars[start - 2] == ":" && chars[start - 1] == ":"
                if path || (chars[start - 1] == "." && !spread) { continue }
            }
            let before = chars[..<start].last { $0 != " " && $0 != "\t" }
            let after = chars[end...].first { $0 != " " && $0 != "\t" }
            if after == ":", end + 1 >= chars.count || chars[end + 1] != ":", before == nil || "(,{".contains(before!) { continue }
            return true
        }
        return false
    }
}
