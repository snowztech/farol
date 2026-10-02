import AppKit
import FarolCore

/// The selected session's merge, rebase, cherry-pick or revert while git is stopped on it.
/// Git is only asked again when something under .git changes, so a checkout with nothing going on costs one call.
final class MergeModel: ObservableObject {
    @Published private(set) var root: String?
    @Published private(set) var operation: Merge.Operation?
    @Published private(set) var conflicts: [Merge.Conflict] = []
    /// Files resolved here during this operation. Git no longer lists them, but they stay in the list with a check.
    @Published private(set) var resolved: [String] = []
    /// Conflicted files git's rerere already resolved like last time, still waiting for you to look.
    @Published private(set) var reused: Set<String> = []
    /// Conflicted files changed on disk since git stopped, by you or an agent, with the conflicts still marked in them.
    /// The columns start from git's versions, so Mark Resolved would write over those changes.
    @Published private(set) var edited: [String: Int] = [:]
    /// Edited files you chose to resolve from git's versions anyway.
    @Published private(set) var editsSetAside: Set<String> = []
    /// The commits of a rebase or of `git am`, done, current and to come.
    @Published private(set) var steps: [Merge.Step] = []
    /// For a file both sides made executable or not, each their own way: what you picked, by path.
    @Published var executable: [String: Bool] = [:]
    /// Lines that differ only in spacing count as the same, so such conflicts settle themselves.
    @Published var ignoreWhitespace = UserDefaults.standard.bool(forKey: "merge.ignoreWhitespace") {
        didSet { UserDefaults.standard.set(ignoreWhitespace, forKey: "merge.ignoreWhitespace") }
    }
    @Published var selected: String?
    @Published private(set) var isBusy = false

    /// What resolving a file took, for the summary once every file is done.
    struct Summary: Equatable {
        var decided = 0
        var automatic = 0
        var warnings: [Merge.Undeclared] = []
        /// Taken as git's rerere left it.
        var reused = false
        /// Taken as you or an agent left it on disk.
        var onDisk = false
    }

    @Published private(set) var summaries: [String: Summary] = [:]
    /// The command that runs the project's tests, guessed or set by you for this checkout.
    @Published private(set) var testCommand: String?
    private var testCommandKey: String? { root.map { "merge.testCommand.\($0)" } }

    private var watchers: [FolderWatcher] = []
    private var gitDir: String?
    private var pending: DispatchWorkItem?

    var hasConflicts: Bool { operation != nil && !conflicts.isEmpty }

    func follow(_ root: String?) {
        guard root != self.root else { return }
        self.root = root
        watchers = []
        gitDir = nil
        operation = nil
        conflicts = []
        reused = []
        edited = [:]
        editsSetAside = []
        executable = [:]
        steps = []
        resolved = []
        summaries = [:]
        selected = nil
        testCommand = nil
        guard let root else { return }
        DispatchQueue.global(qos: .utility).async {
            let gitDir = Merge.gitDirectory(of: root)
            let guessed = Merge.testCommand(in: root)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root else { return }
                self.gitDir = gitDir
                self.testCommand = self.testCommandKey.flatMap { UserDefaults.standard.string(forKey: $0) } ?? guessed
                // A worktree keeps its git state in the main repo, outside the folder being watched.
                let folders = [root] + (gitDir.map { $0.hasPrefix(root + "/") ? [] : [$0] } ?? [])
                self.watchers = folders.map { FolderWatcher($0) { [weak self] in self?.changed($0) } }
                self.refresh()
            }
        }
    }

    func refresh() {
        pending?.cancel()
        guard let root else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let operation = Merge.operation(in: root)
            let conflicts = operation.map { Merge.conflicts(in: root, $0.kind) } ?? []
            let reused = Merge.reused(conflicts, in: root)
            let edited = operation.map { Merge.edited(conflicts, skipping: reused, in: root, $0.kind) } ?? [:]
            let restaged = operation.map { Merge.restagedByRerere(conflicts, in: root, $0.kind) } ?? []
            let steps = [.rebase, .am].contains(operation?.kind) ? Merge.rebaseSteps(in: root) : []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root else { return }
                // The next commit of a rebase is a new set of conflicts, so the checks start over.
                if operation?.kind != self.operation?.kind || operation?.step != self.operation?.step {
                    self.resolved = []
                    self.summaries = [:]
                    self.editsSetAside = []
                    self.executable = [:]
                }
                // With rerere.autoUpdate git stages these itself, so they are listed as resolved, the way rerere did it.
                for path in restaged where !self.resolved.contains(path) {
                    self.resolved.append(path)
                    self.summaries[path] = Summary(reused: true)
                }
                self.operation = operation
                self.conflicts = conflicts
                self.reused = reused
                self.edited = edited
                self.steps = steps
                let listed = conflicts.map(\.path) + self.resolved
                if self.selected.map({ !listed.contains($0) }) ?? true { self.selected = conflicts.first?.path }
            }
        }
    }

    /// Git rewrites a handful of files under .git for every step, so changes wait a moment and refresh once.
    /// A conflicted file changing on disk counts too, since it may now differ from what git left there.
    private func changed(_ paths: [String]) {
        // File events carry real paths, and the checkout may be reached through a link like /tmp.
        let top = root.map { ($0 as NSString).resolvingSymlinksInPath }
        let files = Set(conflicts.compactMap { conflict in top.map { $0 + "/" + conflict.path } })
        let relevant = paths.contains { path in
            if files.contains(path) { return true }
            guard let gitDir, path.hasPrefix(gitDir + "/") else { return false }
            let name = String(path.dropFirst(gitDir.count + 1))
            return ["index", "HEAD", "MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"].contains(name)
                || name.hasPrefix("rebase-merge") || name.hasPrefix("rebase-apply")
        }
        guard relevant else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func status(of path: String) -> Merge.Conflict.Status? {
        conflicts.first { $0.path == path }?.status
    }

    func conflict(_ path: String) -> Merge.Conflict? {
        conflicts.first { $0.path == path }
    }

    /// Whether the three columns can show the file. Links, submodules and files that differ only by mode are whole-file choices.
    func isTextual(_ path: String) -> Bool {
        conflict(path)?.isTextual ?? false
    }

    /// Whether the file changed on disk in a way the columns don't show, and you haven't set that aside.
    func hasOutsideEdits(_ path: String) -> Bool {
        edited[path] != nil && !editsSetAside.contains(path)
    }

    /// Stages the file as it is on disk. Only once no conflict is marked in it.
    func useFileOnDisk(_ path: String, failed: @escaping (String, String) -> Void) {
        guard edited[path] == 0 else { return }
        summaries[path] = Summary(onDisk: true)
        run(path, failed: failed) { try Merge.keep(path, in: $0) }
    }

    /// Resolves the file from git's versions in the columns, which writes over what changed on disk.
    func setEditsAside(_ path: String) {
        editsSetAside.insert(path)
    }

    /// The three versions of a file, read off the main thread.
    func versions(of path: String, _ done: @escaping (Merge.Versions) -> Void) {
        guard let root, let kind = operation?.kind else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let versions = Merge.versions(of: path, in: root, kind)
            DispatchQueue.main.async { done(versions) }
        }
    }

    /// A resolved file as it now is, against HEAD.
    func resolvedFile(_ path: String, _ done: @escaping (Diff.File) -> Void) {
        guard let root else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let file = Merge.resolvedPreview(path, in: root)
            DispatchQueue.main.async { done(file) }
        }
    }

    func resolve(_ path: String, with text: String, summary: Summary, failed: @escaping (String, String) -> Void) {
        summaries[path] = summary
        let executable = conflict(path)?.modeConflict == true ? executable[path] : nil
        run(path, failed: failed) { try Merge.resolve(path, with: text, executable: executable, in: $0) }
    }

    /// Remembered for this checkout, so the next rebase offers it straight away.
    func setTestCommand(_ command: String) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = testCommandKey, !command.isEmpty else { return }
        UserDefaults.standard.set(command, forKey: key)
        testCommand = command
    }

    /// Puts a file you marked resolved back in conflict, to decide it again. Possible until you continue.
    func reopen(_ path: String, failed: @escaping (String, String) -> Void) {
        guard let root, !isBusy else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Merge.reopen(path, in: root) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isBusy = false
                if case .failure(let error) = result {
                    failed("Couldn't reopen \((path as NSString).lastPathComponent)", String(describing: error))
                } else {
                    self.resolved.removeAll { $0 == path }
                    self.summaries[path] = nil
                    self.selected = path
                }
                self.refresh()
            }
        }
    }

    /// Stages a file as rerere resolved it.
    func useReused(_ path: String, failed: @escaping (String, String) -> Void) {
        summaries[path] = Summary(reused: true)
        run(path, failed: failed) { try Merge.keep(path, in: $0) }
    }

    func keep(_ path: String, failed: @escaping (String, String) -> Void) {
        run(path, failed: failed) { try Merge.keep(path, in: $0) }
    }

    func delete(_ path: String, failed: @escaping (String, String) -> Void) {
        run(path, failed: failed) { try Merge.delete(path, in: $0) }
    }

    func take(mine: Bool, _ path: String, failed: @escaping (String, String) -> Void) {
        guard let kind = operation?.kind else { return }
        run(path, failed: failed) { try Merge.take(mine: mine, path, in: $0, kind) }
    }

    /// What git prepared for the commit Continue makes, to start the message sheet from.
    func preparedMessage() -> String {
        root.flatMap { Merge.message(in: $0) } ?? ""
    }

    func proceed(message: String? = nil, failed: @escaping (String, String) -> Void) {
        guard let kind = operation?.kind else { return }
        run(nil, failed: failed) { try Merge.proceed(kind, message: message, in: $0) }
    }

    func skip(failed: @escaping (String, String) -> Void) {
        guard let kind = operation?.kind else { return }
        run(nil, failed: failed) { try Merge.skip(kind, in: $0) }
    }

    func abort(failed: @escaping (String, String) -> Void) {
        guard let kind = operation?.kind else { return }
        run(nil, failed: failed) { try Merge.abort(kind, in: $0) }
    }

    /// Runs one git step off the main thread. A resolved file moves to the next one still in conflict.
    private func run(_ path: String?, failed: @escaping (String, String) -> Void, _ work: @escaping (String) throws -> Void) {
        guard let root, !isBusy else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(root) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isBusy = false
                if case .failure(let error) = result {
                    failed(path == nil ? "Git stopped" : "Couldn't resolve \((path! as NSString).lastPathComponent)", String(describing: error))
                } else if let path {
                    if !self.resolved.contains(path) { self.resolved.append(path) }
                    self.selected = self.conflicts.first { $0.path != path }?.path ?? path
                }
                self.refresh()
            }
        }
    }
}
