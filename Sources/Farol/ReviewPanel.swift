import AppKit
import FarolCore
import SwiftUI

/// The selected session's changes. The count in the title bar is always current. The full diff is only read while the panel is open.
final class ReviewModel: ObservableObject {
    enum Row: Identifiable {
        case header(Diff.File, collapsed: Bool)
        /// The file's lines, drawn by one text view so a selection can cross them.
        /// Comments on lines split it, and `rows` says which part this is. Nil is the whole file.
        case body(Diff.File, rows: Range<Int>?)
        case note(file: String, String)
        /// A request's comments on one line, under it.
        case thread(LineRef, [Forge.Discussion.Comment])
        /// The field for a new comment on a line.
        case composer(LineRef)

        var id: String {
            switch self {
            case .header(let file, _): file.path
            case .body(let file, let rows): "\(file.path)#body\(rows?.lowerBound ?? 0)"
            case .note(let file, _): "\(file)#note"
            case .thread(let line, _): "\(line.path)#thread\(line.old ? "-" : "")\(line.line)"
            case .composer(let line): "\(line.path)#composer"
            }
        }
    }

    /// A line of a request's diff: its number in the new file, or in the old one for a removed line.
    struct LineRef: Hashable {
        let path: String
        let line: Int
        let old: Bool
    }

    @Published private(set) var root: String?
    @Published private(set) var branch: String?
    @Published private(set) var scope = Diff.Scope.uncommitted
    /// Branches to compare with, the base one first.
    @Published private(set) var branches: [String] = []
    @Published private(set) var stat = Diff.Stat()
    /// What the title bar counts: your changes, even while the panel shows a commit.
    @Published private(set) var changes = Diff.Stat()
    /// False while the panel shows a commit or a request rather than your own work.
    var showsYours: Bool { scope.isYours }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var error: String?
    @Published var isOpen = false {
        didSet {
            guard isOpen != oldValue else { return }
            // A commit or a request is only looked at while the panel is open. Closing it brings back what the title bar counts.
            if !isOpen, !scope.isYours, let root {
                chosenScope[root] = yourScope
                scope = yourScope ?? .uncommitted
                fetchedRequest = nil
            }
            refresh()
            if isOpen { checkRequest() }
        }
    }
    /// A file to bring into view once the diff is read. The id changes each time, so asking twice for one file scrolls again.
    @Published private(set) var focus: (path: String, id: UUID)?
    private var pendingFocus: String?
    /// The subject of the commit being shown, for the compare menu.
    @Published private(set) var commitSubject: String?
    /// The request being shown, for the compare menu and the link to its page.
    @Published private(set) var shownRequest: Forge.Request?
    /// Its description and comments, above its files. Nil while they are read, or without the forge's tool.
    @Published private(set) var discussion: Forge.Discussion? {
        didSet { rebuild() }
    }
    /// What the conversation lists: the comments that aren't shown under a line of the diff.
    @Published private(set) var conversation: [Forge.Discussion.Comment] = []
    /// The line a new comment is being written on, and its text so far.
    @Published private(set) var composing: LineRef?
    @Published var draft = ""
    @Published private(set) var isSending = false
    @Published private(set) var sendError: String?
    /// While a commit or a push runs.
    @Published private(set) var isShipping = false
    /// The commit sheet is open, from the Commit button or ⌥⌘C.
    @Published var askingCommit = false
    /// Where the branch is pushed, when that is GitHub or GitLab, to offer opening a pull request there.
    @Published private(set) var forge: Forge?
    /// Whether the branch has an open pull request. Unknown without the forge's command line tool.
    @Published private(set) var request = Forge.RequestState.unknown
    /// The steps of the request's pipeline. Empty when it has none, or without the forge's tool.
    @Published private(set) var checks: [Forge.Check] = []
    /// Commits on the branch that its base doesn't have. With none, there is nothing to make a request of.
    @Published private(set) var ahead = 0
    /// Commits the branch has left to push, as of the last fetch. Zero without a remote.
    @Published private(set) var unpushed = 0
    /// The files a commit would take. "Changes since main" also shows work that is already committed.
    @Published private(set) var uncommittedPaths: Set<String> = []
    var uncommitted: Int { uncommittedPaths.count }
    /// Uncommitted files you unticked, per checkout. They stay out of the next commit.
    @Published private var leftOut: [String: Set<String>] = [:]
    var excluded: Set<String> { canChooseFiles ? root.flatMap { leftOut[$0] } ?? [] : [] }
    /// False while git is stopped on a merge, a rebase or a cherry-pick, where it only takes a commit of everything.
    /// The ticks are hidden then, so nobody is led into git's refusal.
    @Published private(set) var canChooseFiles = true
    /// What you were looking at before a commit or a request, to come back to.
    private var yourScope: Diff.Scope?
    /// The request whose files are loaded. Its diff doesn't move as you work, so the forge is asked once.
    private var fetchedRequest: Int?
    /// The last branch asked about and when, so two asks moments apart make one network call.
    private var lastRequestCheck: (key: String, at: Date)?
    /// In a task folder, each repo and its changes, for the tabs and the title bar's total. Empty outside one.
    @Published private(set) var taskRepos: [(path: String, stat: Diff.Stat)] = []
    /// Your changes across every repo of a task, or just this checkout's.
    var total: Diff.Stat {
        guard !taskRepos.isEmpty else { return changes }
        return taskRepos.reduce(into: Diff.Stat()) { sum, repo in
            sum.files += repo.stat.files
            sum.added += repo.stat.added
            sum.removed += repo.stat.removed
        }
    }
    /// Gets the first task repo with changes once they are counted, so the panels can start there.
    var onFirstCounts: ((String) -> Void)?
    private var countedOnce = true
    private var taskWatcher: FolderWatcher?
    /// The ignored folders of every task repo, so a build in one of them doesn't count everything again.
    private var taskIgnored: [String] = []
    private var pendingTask: DispatchWorkItem?
    /// Each task repo's default scope, worked out once since it takes a few git calls.
    private var defaultScopes: [String: Diff.Scope] = [:]

    private var files: [Diff.File] = []
    /// Files with unmodified lines opened, as the diff gave them and as shown. Kept while the diff of the file stays the same.
    private var expanded: [String: (base: Diff.File, shown: Diff.File)] = [:]
    private var expandedScope: Diff.Scope?
    private var collapsed: Set<String> = []
    /// Your choice per checkout, so switching sessions doesn't reset it.
    private var chosenScope: [String: Diff.Scope] = [:]
    private var ignored: [String] = []
    private var watcher: FolderWatcher?
    private var pending: DispatchWorkItem?
    /// Set while a new checkout's scope is being worked out. Counting with the last checkout's scope would flash the wrong numbers.
    private var scopePending = false
    /// The next look at the checks, while some are still running.
    private var poll: DispatchWorkItem?
    /// A push starts a pipeline, but the forge takes a moment to list it. Until then, no checks doesn't mean none are coming.
    private var checksDue = Date.distantPast

    /// Big diffs, like a lockfile, start folded so they don't bury everything else.
    private static let foldedAbove = 800

    init() {
        // You create the request in the browser, so coming back to Farol is when it may have appeared.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.isOpen == true { self?.checkRequest() }
        }
    }

    /// Follows another checkout, or stops when `root` is nil, as outside a git repo.
    func follow(_ root: String?, branch: String?) {
        let branchChanged = branch != self.branch
        self.branch = branch
        guard root != self.root || branchChanged else { return refresh() }
        request = .unknown
        checks = []
        let rootChanged = root != self.root
        self.root = root
        if rootChanged {
            watcher = nil
            files = []
            expanded = [:]
            collapsed = []
            rows = []
            stat = Diff.Stat()
            changes = Diff.Stat()
            uncommittedPaths = []
            ahead = 0
            unpushed = 0
            forge = nil
            ignored = []
            fetchedRequest = nil
        }
        guard let root else { return }
        if rootChanged { watcher = FolderWatcher(root) { [weak self] in self?.changed($0) } }
        scopePending = true
        DispatchQueue.global(qos: .userInitiated).async {
            let base = Diff.baseBranch(in: root)
            let local = Diff.branches(in: root)
            let branches = (base.map { [$0] } ?? []) + local.filter { base != $0 && base != "origin/\($0)" }
            let scope = Diff.defaultScope(in: root)
            // The counts only need the scope, so they are read before the rest is known.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root else { return }
                self.branches = branches
                self.scope = self.chosenScope[root] ?? scope
                self.scopePending = false
                self.refresh()
            }
            let ignored = Self.ignoredPrefixes(in: root)
            let forge = Forge.detect(in: root)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root else { return }
                self.forge = forge
                self.ignored = ignored
                if self.discussion == nil { self.loadDiscussion() }
                self.checkRequest()
            }
        }
    }

    /// Counts the changes of every repo in a task folder, or stops with no repos.
    func follow(task repos: [String]) {
        // Called at every prompt, which is also how a commit from the terminal shows up.
        guard repos != taskRepos.map(\.path) else { return refreshTask() }
        pendingTask?.cancel()
        taskRepos = repos.map { ($0, Diff.Stat()) }
        taskIgnored = []
        defaultScopes = [:]
        countedOnce = false
        // The repos sit side by side in the task folder, so one watcher sees them all.
        // A commit writes to the repo's own .git, outside the folder, so its counts catch up at the next prompt or turn end.
        taskWatcher = repos.first.map { first in
            FolderWatcher((first as NSString).deletingLastPathComponent) { [weak self] in self?.taskChanged($0) }
        }
        refreshTask()
    }

    private func taskChanged(_ paths: [String]) {
        guard Self.matters(paths, ignored: taskIgnored) else { return }
        pendingTask?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshTask() }
        pendingTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func refreshTask() {
        let repos = taskRepos.map(\.path)
        guard !repos.isEmpty else { return }
        let chosen = chosenScope, known = defaultScopes
        DispatchQueue.global(qos: .userInitiated).async {
            var stats = [Diff.Stat](repeating: Diff.Stat(), count: repos.count)
            var scopes = [Diff.Scope?](repeating: nil, count: repos.count)
            var ignored = [[String]](repeating: [], count: repos.count)
            let lock = NSLock()
            // Each repo answers on its own, so a big one doesn't hold up the rest.
            DispatchQueue.concurrentPerform(iterations: repos.count) { index in
                let repo = repos[index]
                let fallback = known[repo] ?? Diff.defaultScope(in: repo)
                var scope = chosen[repo] ?? fallback
                // A commit or a request you're looking at isn't your changes, which is what the counts are.
                if !scope.isYours { scope = fallback }
                let stat = (try? Diff.stat(in: repo, scope)) ?? Diff.Stat()
                let repoIgnored = Self.ignoredPrefixes(in: repo)
                lock.withLock { (stats[index], scopes[index], ignored[index]) = (stat, fallback, repoIgnored) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.taskRepos.map(\.path) == repos else { return }
                self.taskRepos = Array(zip(repos, stats))
                self.taskIgnored = ignored.flatMap { $0 }
                for (repo, scope) in zip(repos, scopes) { self.defaultScopes[repo] = scope }
                if !self.countedOnce {
                    self.countedOnce = true
                    if let changed = self.taskRepos.first(where: { !$0.stat.isEmpty }) { self.onFirstCounts?(changed.path) }
                }
            }
        }
    }

    /// Shows what one commit changed, as from the git graph.
    func show(commit hash: String, subject: String, file: String? = nil) {
        guard let root else { return }
        pendingFocus = file
        commitSubject = subject
        browse(.commit(hash), in: root)
    }

    /// Shows what an open request changes, as from the git graph.
    func show(request: Forge.Request) {
        guard let root else { return }
        if shownRequest?.number != request.number {
            discussion = nil
            composing = nil
            draft = ""
        }
        shownRequest = request
        // Another click reads it again, for commits pushed since.
        fetchedRequest = nil
        browse(.request(request.number), in: root)
        loadDiscussion()
    }

    /// Also runs once the forge is known, for a request shown before it was.
    private func loadDiscussion() {
        guard let root, let forge, let request = shownRequest, scope == .request(request.number) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let discussion = forge.discussion(ofRequest: request.number, in: root)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root, self.shownRequest?.number == request.number else { return }
                self.discussion = discussion
            }
        }
    }

    /// The request on screen takes comments on its lines from here.
    var canComment: Bool {
        guard let request = shownRequest, scope == .request(request.number) else { return false }
        return forge?.takesLineComments == true && discussion?.head != nil
    }

    func startComment(on line: LineRef) {
        if composing != line { draft = "" }
        composing = line
        sendError = nil
        rebuild()
    }

    func cancelComment() {
        composing = nil
        sendError = nil
        rebuild()
    }

    /// Sends the draft, then reads the conversation again so the comment shows under its line.
    func sendComment() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root, let forge, let line = composing, let request = shownRequest, let discussion,
              let file = files.first(where: { $0.path == line.path }), !text.isEmpty, !isSending else { return NSSound.beep() }
        // GitLab places a comment by both numbers when the line is unchanged, and by both paths when the file was renamed.
        let place = Forge.LinePlace(path: line.path, oldPath: file.oldPath ?? line.path,
                                    newLine: line.old ? nil : line.line,
                                    oldLine: line.old ? line.line : file.oldLine(forNew: line.line))
        isSending = true
        sendError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let sent = Result {
                try forge.comment(text, onRequest: request.number, at: place, of: discussion, in: root)
            }
            let updated = (try? sent.get()) == nil ? nil : forge.discussion(ofRequest: request.number, in: root)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSending = false
                guard self.root == root, self.shownRequest?.number == request.number else { return }
                if case .failure(let error) = sent { return self.sendError = String(describing: error) }
                self.draft = ""
                // Without the conversation read back, the comment wouldn't show. The field stays to say it went.
                guard let updated else { return self.sendError = "Sent, but couldn't read it back. View on \(forge.name) shows it." }
                self.composing = nil
                self.discussion = updated
            }
        }
    }

    /// Unfolds a file and brings it into view, as from a comment left on one of its lines.
    func reveal(_ path: String) {
        guard files.contains(where: { $0.path == path }) else { return }
        collapsed.remove(path)
        rebuild()
        focus = (path, UUID())
    }

    private func browse(_ scope: Diff.Scope, in root: String) {
        if self.scope.isYours { yourScope = chosenScope[root] ?? self.scope }
        chosenScope[root] = scope
        self.scope = scope
        refresh()
    }

    /// Goes back from a commit or a request to the changes shown before it. False when your own changes are shown.
    func showYours() -> Bool {
        guard isOpen, !scope.isYours, let root else { return false }
        chosenScope[root] = yourScope
        scope = yourScope ?? .uncommitted
        refresh()
        return true
    }

    func choose(_ scope: Diff.Scope) {
        guard let root, scope != self.scope else { return }
        chosenScope[root] = scope
        self.scope = scope
        refresh()
        refreshTask()
    }

    /// Opens the commit sheet when there is something to commit.
    func askCommit() {
        guard root != nil, uncommitted > 0, !isShipping else { return NSSound.beep() }
        askingCommit = true
    }

    /// Takes a file out of the next commit, or back in.
    func toggleExcluded(_ path: String) {
        guard let root else { return }
        if leftOut[root, default: []].remove(path) == nil { leftOut[root, default: []].insert(path) }
    }

    /// Unticks every uncommitted file, or ticks them all again.
    func excludeAll(_ all: Bool) {
        guard let root else { return }
        leftOut[root] = all ? uncommittedPaths : []
    }

    /// Whether a file shown in the panel has a tick: only a file with uncommitted changes can go in a commit.
    func isTicked(_ path: String) -> Bool? {
        if !scope.isYours { return nil }
        return canChooseFiles && uncommittedPaths.contains(path) ? !excluded.contains(path) : nil
    }

    /// Commits when there is a message, every uncommitted file or only `paths`, then goes as far as `next` says.
    /// `failed` gets a title and git's own message.
    func ship(message: String?, only paths: [String]? = nil, then next: AfterCommit, failed: @escaping (String, String) -> Void) {
        guard let root, !isShipping else { return }
        // With the forge's tool the request is created right here. Without it, its form opens in the browser.
        let create = next == .openRequest && canCreateRequest ? forge : nil
        let link = next == .openRequest && create == nil ? branch.flatMap { forge?.newRequest(from: $0) } : nil
        let branch = branch
        isShipping = true
        DispatchQueue.global(qos: .userInitiated).async {
            var committed = false
            let failure: (String, String)? = {
                if let message {
                    do {
                        if let paths { try History.commit(message, only: paths, in: root) } else { try History.commitAll(message, in: root) }
                        committed = true
                    } catch { return ("Couldn't commit", String(describing: error)) }
                }
                guard next != .nothing else { return nil }
                do { try History.push(in: root) } catch {
                    return (message == nil ? "Couldn't push" : "Committed, but couldn't push", String(describing: error))
                }
                guard let create, let branch else { return nil }
                do { try create.createRequest(for: branch, in: root) } catch {
                    return ("Pushed, but couldn't create the \(create.request)", String(describing: error))
                }
                return nil
            }()
            // Read here, while the button is still busy, so it turns straight into "PR #5".
            let created = create.flatMap { forge in branch.map { forge.request(for: $0, in: root) } }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isShipping = false
                // What was left out of this commit is the next one's to decide.
                if committed { self.leftOut[root] = nil }
                self.refreshTask()
                if let failure { failed(failure.0, failure.1) } else if let link { NSWorkspace.shared.open(link) }
                self.refresh()
                if let created, self.root == root, self.branch == branch { self.request = created }
                if next != .nothing, failure == nil { self.checksDue = Date() + 60 }
                // A push or a new request changes what the forge says, so it's asked even if it just was.
                self.checkRequest(force: true)
            }
        }
    }

    /// The files a commit would take, for the commit sheet. Read on demand, since the panel may be showing another scope.
    func uncommittedFiles(_ done: @escaping ([Diff.File]) -> Void) {
        guard let root else { return done([]) }
        DispatchQueue.global(qos: .userInitiated).async {
            let files = (try? Diff.files(in: root, .uncommitted)) ?? []
            DispatchQueue.main.async { done(files) }
        }
    }

    /// Asks the forge whether the branch has an open request. A network call, so only when something may have changed it.
    /// Following a repo and opening the panel both ask, moments apart, so a branch asked about in the last 10 seconds waits.
    /// `force` is for when something just changed: a push, a request created, a pipeline still running.
    func checkRequest(force: Bool = false) {
        guard let root, let branch, let forge, !isOnBaseBranch else { return }
        let key = root + "\n" + branch
        if !force, let last = lastRequestCheck, last.key == key, Date().timeIntervalSince(last.at) < 10 { return }
        lastRequestCheck = (key, Date())
        DispatchQueue.global(qos: .utility).async {
            let (state, checks) = forge.requestAndChecks(for: branch, in: root)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root, self.branch == branch else { return }
                self.request = state
                self.checks = checks
                // Nothing local says a pipeline moved on, so the forge is asked again until it settles.
                self.poll?.cancel()
                guard self.isOpen, checks.contains(where: { $0.state == .running }) || Date() < self.checksDue else { return }
                let poll = DispatchWorkItem { [weak self] in self?.checkRequest(force: true) }
                self.poll = poll
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: poll)
            }
        }
    }

    /// The forge's tool answered and found no request, so it can create one.
    var canCreateRequest: Bool { request == .none && canStartRequest }

    /// False once the branch has a request, or on the base branch, where there is nothing to request.
    var canStartRequest: Bool {
        if case .open = request { return false }
        return forge != nil && branch != nil && !isOnBaseBranch
    }

    /// True once everything is committed and there is no request to open, so a push is the next step.
    var canPush: Bool { uncommitted == 0 && unpushed > 0 && !(canStartRequest && ahead > 0) }

    /// The branch everything is compared with, like main. A request from it into itself makes no sense.
    var isOnBaseBranch: Bool {
        guard let branch, let base = branches.first else { return false }
        return base == branch || base == "origin/\(branch)"
    }

    func toggle(_ path: String) {
        if collapsed.remove(path) == nil { collapsed.insert(path) }
        rebuild()
    }

    /// Lines shown by one click on a gap's button. A smaller gap opens whole.
    private static let expandStep = 20

    var canExpand: Bool { !scope.isRequest }

    /// Shows more of the unmodified lines in `gap`, from its top, next to the change above, or from its bottom.
    func expand(_ path: String, gap: Range<Int>, fromTop: Bool) {
        guard canExpand, let root, let file = files.first(where: { $0.path == path }) else { return }
        let scope = scope
        let part = gap.count <= Self.expandStep * 2 ? gap
            : fromTop ? gap.lowerBound..<(gap.lowerBound + Self.expandStep) : (gap.upperBound - Self.expandStep)..<gap.upperBound
        DispatchQueue.global(qos: .userInitiated).async {
            let text = Diff.newLines(of: path, in: root, scope)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root, self.scope == scope, let text,
                      let at = self.files.firstIndex(where: { $0.path == file.path }) else { return }
                let shown = self.files[at].expanding(part, from: text)
                self.expanded[path] = (self.expanded[path]?.base ?? file, shown)
                self.files[at] = shown
                self.rebuild()
            }
        }
    }

    /// Reads the counts, and the whole diff when the panel is open, off the main thread.
    func refresh() {
        pending?.cancel()
        guard let root, !scopePending else { return }
        let scope = scope, base = branches.first, branch = branch
        let withFiles = isOpen && scope != fetchedRequest.map(Diff.Scope.request)
        let yours = scope.isYours ? scope : yourScope ?? .uncommitted
        DispatchQueue.global(qos: .userInitiated).async {
            // In the order you see them: the open panel's diff, the title bar's counts, then what only feeds the buttons.
            let files = withFiles ? Result { try Diff.files(in: root, scope) } : nil
            // A request's counts come with its files. Asking the forge again for them would be a second network call.
            let stat: Result<Diff.Stat, Error>? = if case .request = scope {
                files.map { $0.map(Diff.Stat.init) }
            } else {
                Result { try Diff.stat(in: root, scope) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root, self.scope == scope else { return }
                if let stat { self.stat = (try? stat.get()) ?? Diff.Stat() }
                if files != nil { self.error = (try? files?.get()) == nil ? "Couldn't read the changes." : nil }
                // Failed or not, the request isn't asked for again on every file change. Another click on it retries.
                if files != nil, case .request(let number) = scope { self.fetchedRequest = number }
                if let files = try? files?.get() {
                    let known = Set(self.files.map(\.path))
                    for file in files where !known.contains(file.path) && file.added + file.removed > Self.foldedAbove {
                        self.collapsed.insert(file.path)
                    }
                    if self.expandedScope != scope { self.expanded = [:] }
                    self.expandedScope = scope
                    self.files = files.map { file in
                        if let kept = self.expanded[file.path], kept.base == file { return kept.shown }
                        self.expanded[file.path] = nil
                        return file
                    }
                    if let path = self.pendingFocus, files.contains(where: { $0.path == path }) {
                        // A big file starts folded, which would scroll to a header with nothing under it.
                        self.collapsed.remove(path)
                        self.pendingFocus = nil
                        self.rebuild()
                        self.focus = (path, UUID())
                    } else {
                        self.rebuild()
                    }
                }
            }
            let changes = (yours == scope ? stat : nil) ?? Result { try Diff.stat(in: root, yours) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root, self.scope == scope else { return }
                self.changes = (try? changes.get()) ?? Diff.Stat()
            }
            let ahead = base.map { History.commitsAhead(of: $0, in: root) } ?? 0
            let unpushed = branch.map { History.unpushed($0, in: root) } ?? 0
            let uncommitted = Set((try? Diff.uncommittedPaths(in: root)) ?? [])
            let stopped = Merge.operation(in: root) != nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root, self.scope == scope else { return }
                self.uncommittedPaths = uncommitted
                if self.canChooseFiles == stopped { self.canChooseFiles = !stopped }
                if let left = self.leftOut[root], !left.isSubset(of: uncommitted) { self.leftOut[root] = left.intersection(uncommitted) }
                self.ahead = ahead
                // A push from the terminal starts a pipeline just the same.
                if unpushed == 0, self.unpushed > 0, self.isOpen {
                    self.checksDue = Date() + 60
                    self.checkRequest(force: true)
                }
                self.unpushed = unpushed
            }
        }
    }

    /// Whether a change on disk can change what git reports. Of `.git` only the index and HEAD do.
    private static func matters(_ paths: [String], ignored: [String]) -> Bool {
        paths.contains { path in
            if path.contains("/.git/") { return path.hasSuffix("/.git/index") || path.hasSuffix("/.git/HEAD") }
            return !ignored.contains { path.hasPrefix($0) }
        }
    }

    /// Git's ignored folders, as prefixes. Read again after each change, since a build or an install makes new ones.
    private static func ignoredPrefixes(in root: String) -> [String] {
        Files.ignored(in: root).map { $0 + "/" }
    }

    private func rereadIgnored() {
        guard let root else { return }
        DispatchQueue.global(qos: .utility).async {
            let ignored = Self.ignoredPrefixes(in: root)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root else { return }
                self.ignored = ignored
            }
        }
    }

    /// Agents write in bursts, so changes wait a moment and refresh once.
    private func changed(_ paths: [String]) {
        guard Self.matters(paths, ignored: ignored) else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refresh()
            self?.rereadIgnored()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func rebuild() {
        let showsRequest = shownRequest.map { scope == .request($0.number) } ?? false
        // Comments on lines go under them. One whose line the diff no longer shows stays in the conversation.
        var threads: [LineRef: [Forge.Discussion.Comment]] = [:]
        var conversation: [Forge.Discussion.Comment] = []
        for comment in showsRequest ? discussion?.comments ?? [] : [] {
            if !comment.outdated, let path = comment.path, let line = comment.line, let file = files.first(where: { $0.path == path }),
               DiffTextView.row(of: line, old: comment.old, in: file) != nil {
                threads[LineRef(path: path, line: line, old: comment.old), default: []].append(comment)
            } else {
                conversation.append(comment)
            }
        }
        self.conversation = conversation
        let composing = showsRequest ? composing : nil

        var rows: [Row] = []
        for file in files {
            let folded = collapsed.contains(file.path)
            rows.append(.header(file, collapsed: folded))
            if folded { continue }
            if file.isBinary { rows.append(.note(file: file.path, "Binary file")) }
            if file.hunks.isEmpty { continue }
            var lines = Set(threads.keys.filter { $0.path == file.path })
            if let composing, composing.path == file.path { lines.insert(composing) }
            let placed = lines.compactMap { line in DiffTextView.row(of: line.line, old: line.old, in: file).map { (row: $0, line: line) } }
            // The diff is cut after each line with comments, so they show right under it.
            var start = 0
            for (row, here) in Dictionary(grouping: placed, by: \.row).sorted(by: { $0.key < $1.key }) {
                rows.append(.body(file, rows: start..<(row + 1)))
                start = row + 1
                for line in here.map(\.line) {
                    if let comments = threads[line] { rows.append(.thread(line, comments)) }
                }
                if let composing, here.contains(where: { $0.line == composing }) { rows.append(.composer(composing)) }
            }
            let count = DiffTextView.rowCount(file)
            if start == 0 { rows.append(.body(file, rows: nil)) } else if start < count { rows.append(.body(file, rows: start..<count)) }
        }
        self.rows = rows
    }
}

struct ReviewPanel: View {
    static let defaultWidth: CGFloat = 560

    @ObservedObject var review: ReviewModel
    @ObservedObject var state: WindowState
    /// Opens a file in the file pane, at a line.
    let open: (String, Int) -> Void
    /// Shows another of the task's repos.
    let pick: (String) -> Void
    let close: () -> Void
    let resize: (CGFloat) -> Void

    @State private var dragStart: CGFloat?

    var body: some View {
        let p = state.palette
        VStack(alignment: .leading, spacing: 0) {
            TaskRepoTabs(review: review, palette: p, pick: pick)
            header(p)
            HStack(spacing: 8) {
                ScopeMenu(review: review, palette: p)
                Spacer(minLength: 0)
                // The slot holds the next step: commit what's there, then open the request for the branch.
                // Where there is no request to open, as on main or once the branch has one, the next step is a push.
                if let forge = review.forge, let request = review.shownRequest, review.scope == .request(request.number) {
                    ShipButton(title: "View on \(forge.name)", help: "Open \(forge.request) #\(request.number) in the browser",
                               busy: false, icon: forge.kind, palette: p) { NSWorkspace.shared.open(request.url) }
                }
                if !isCommit {
                    RequestBadge(review: review, palette: p)
                    if review.uncommitted > 0 {
                        CommitButton(review: review, palette: p)
                    } else if review.canStartRequest, review.ahead > 0 {
                        RequestButton(review: review, palette: p)
                    } else if review.canPush {
                        PushButton(review: review, palette: p)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            Rectangle().fill(p.line).frame(height: 1)
            if let error = review.error {
                message(error, p)
            } else if review.rows.isEmpty {
                message(review.root == nil ? state.noRepoMessage : "No changes.", p)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // A file's header stays at the top while its lines scroll, so it can always be folded or left out.
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                            if let discussion = review.discussion, review.scope == review.shownRequest.map({ .request($0.number) }) {
                                Conversation(description: discussion.description, comments: review.conversation, palette: p, reveal: review.reveal)
                            }
                            ForEach(sections) { section in
                                Section {
                                    ForEach(section.rows) { row(for: $0, p) }
                                } header: {
                                    if let head = section.header {
                                        row(for: head, p).background(p.background).id(head.id)
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .onChange(of: review.focus?.id) {
                        guard let path = review.focus?.path else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(path, anchor: .top) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(p.background)
        .overlay(alignment: .leading) { edge(p) }
        .commitSheet(review, palette: p)
    }

    private struct FileSection: Identifiable {
        let header: ReviewModel.Row?
        var rows: [ReviewModel.Row]
        var id: String { header?.id ?? "" }
    }

    /// The rows cut at each file header, so the header can pin over the rows under it.
    private var sections: [FileSection] {
        var result: [FileSection] = []
        for row in review.rows {
            if case .header = row {
                result.append(FileSection(header: row, rows: []))
            } else if result.isEmpty {
                result.append(FileSection(header: nil, rows: [row]))
            } else {
                result[result.count - 1].rows.append(row)
            }
        }
        return result
    }

    /// Looking at one commit or a request, the working tree plays no part, so there is nothing to offer a commit for.
    private var isCommit: Bool { !review.showsYours }

    private func header(_ p: Palette) -> some View {
        HStack(spacing: 8) {
            Text([review.root.map { ($0 as NSString).lastPathComponent }, review.branch].compactMap { $0 }.joined(separator: ": "))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if !review.stat.isEmpty {
                Text("\(review.stat.files) \(review.stat.files == 1 ? "file" : "files")").foregroundStyle(p.muted)
                Counts(added: review.stat.added, removed: review.stat.removed, palette: p)
            }
            Spacer()
            CloseButton(help: "Close review (⌥⌘R)", palette: p, action: close)
        }
        .font(.system(size: 12))
        .foregroundStyle(p.text)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 38)
    }

    @ViewBuilder private func row(for row: ReviewModel.Row, _ p: Palette) -> some View {
        switch row {
        case .header(let file, let collapsed):
            FileHeader(file: file, collapsed: collapsed, ticked: review.isTicked(file.path), palette: p,
                       tick: { review.toggleExcluded(file.path) },
                       toggle: { review.toggle(file.path) },
                       // A request's files are its branch's, not the ones in your checkout.
                       open: review.scope.isRequest ? nil : { review.root.map { open(($0 as NSString).appendingPathComponent(file.path), file.firstChange) } })
        case .body(let file, let rows):
            DiffText(file: file, rows: rows, colors: p.diff, syntax: p.code,
                     comment: review.canComment ? { review.startComment(on: .init(path: file.path, line: $0, old: $1)) } : nil,
                     expand: review.canExpand ? { review.expand(file.path, gap: $0, fromTop: $1) } : nil)
                .padding(.horizontal, 8)
        case .thread(_, let comments):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                    CommentView(comment: comment, empty: "", palette: p, reveal: nil)
                }
            }
            .padding(.leading, 24)
            .padding(.bottom, 6)
        case .composer(let line):
            LineComposer(review: review, line: line, palette: p).padding(.leading, 24).padding(.bottom, 6)
        case .note(_, let text):
            Text(text).font(.system(size: 12)).foregroundStyle(p.muted).padding(.leading, 58).frame(height: 24)
        }
    }

    private func message(_ text: String, _ p: Palette) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(p.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The line between the terminal and the panel, wide enough to grab and drag.
    private func edge(_ p: Palette) -> some View {
        // At the very edge, so it continues the title bar's column line.
        Rectangle().fill(p.boxed ? .clear : p.line).frame(width: 1)
            .frame(width: 7, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? state.reviewWidth
                    dragStart = start
                    resize(start - drag.translation.width)
                }
                .onEnded { _ in dragStart = nil })
    }
}

/// "⇄ Uncommitted changes ⌃⌄", a quiet select for what the panel compares with, like Warp's.
/// A plain button that opens a native menu, because SwiftUI's menu button drops the ⌃⌄ that says "this is a select".
private struct ScopeMenu: View {
    @ObservedObject var review: ReviewModel
    let palette: Palette

    @State private var hovering = false

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(palette.muted)
                Text(title).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(palette.muted)
            }
            .foregroundStyle(palette.text)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? palette.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onClickableHover { hovering = $0 }
        .hoverTip("Choose what to compare with")
    }

    private var title: String {
        switch review.scope {
        case .uncommitted: "Uncommitted changes"
        case .branch(let base): "Changes since \(Self.name(base))"
        case .commit(let hash): "Commit \(hash.prefix(7))"
        case .request(let number): "\(review.forge?.requestShort ?? "PR") #\(number)"
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        if case .commit(let hash) = review.scope {
            let subject = review.commitSubject.map { ": " + ($0.count > 40 ? $0.prefix(40) + "…" : $0) } ?? ""
            menu.addItem(item("Commit \(hash.prefix(7))" + subject, review.scope))
            menu.addItem(.separator())
        }
        if case .request(let number) = review.scope {
            let title = review.shownRequest.map { ": " + ($0.title.count > 40 ? $0.title.prefix(40) + "…" : $0.title) } ?? ""
            menu.addItem(item("\(review.forge?.requestShort ?? "PR") #\(number)" + title, review.scope))
            menu.addItem(.separator())
        }
        menu.addItem(item("Uncommitted changes", .uncommitted))
        if !review.branches.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Changes since"))
            for branch in review.branches { menu.addItem(item(Self.name(branch), .branch(base: branch))) }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func item(_ title: String, _ scope: Diff.Scope) -> NSMenuItem {
        let item = ActionMenuItem(title: title) { [review] in review.choose(scope) }
        item.state = review.scope == scope ? .on : .off
        return item
    }

    /// origin/main reads as main. The remote is an implementation detail here.
    static func name(_ branch: String) -> String {
        branch.hasPrefix("origin/") ? String(branch.dropFirst("origin/".count)) : branch
    }
}

/// An NSMenuItem that runs a closure, for menus built on the spot.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// "+18 −3" in the diff colors.
struct Counts: View {
    let added: Int
    let removed: Int
    let palette: Palette

    var body: some View {
        HStack(spacing: 4) {
            // A side with nothing to count stays gray, so only real changes take a color.
            Text("+\(added)").foregroundStyle(added == 0 ? palette.muted : palette.added)
            Text("−\(removed)").foregroundStyle(removed == 0 ? palette.muted : palette.removed)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }
}

private struct FileHeader: View {
    let file: Diff.File
    let collapsed: Bool
    /// Whether the file goes in the next commit. Nil when it has nothing to commit.
    let ticked: Bool?
    let palette: Palette
    let tick: () -> Void
    let toggle: () -> Void
    let open: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .foregroundStyle(palette.muted)
                .frame(width: 12)
            if let ticked {
                Button(action: tick) { Tick(on: ticked, palette: palette).frame(height: 34).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .hoverTip(ticked ? "In the next commit. Click to leave it out" : "Left out of the next commit. Click to take it")
            }
            FileIcon(path: file.path)
                .font(.system(size: 11))
                .foregroundStyle(palette.muted)
                .frame(width: 15)
            (Text(folder).foregroundColor(palette.muted) + Text(name).foregroundColor(ticked == false ? palette.muted : palette.text))
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.head)
            if let status { Text(status).font(.system(size: 11)).foregroundStyle(palette.muted) }
            if !file.isBinary {
                Counts(added: file.added, removed: file.removed, palette: palette)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.line))
            }
            Spacer(minLength: 8)
            IconButton(symbol: "square.on.square", help: "Copy path", palette: palette) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            if let open, file.status != .deleted {
                IconButton(symbol: "arrow.up.right.square", help: "Open in the file pane", palette: palette, action: open)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? palette.raised : palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.line))
        // Room between files, so each one reads as its own block.
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onClickableHover { hovering = $0 }
        .onTapGesture(perform: toggle)
    }

    private var folder: String {
        let folder = (file.path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "" : folder + "/"
    }

    private var name: String { (file.path as NSString).lastPathComponent }

    private var status: String? {
        switch file.status {
        case .added: "new"
        case .deleted: "deleted"
        case .renamed: file.oldPath.map { "from \($0)" }
        case .modified: nil
        }
    }
}

/// "api +12 −3   web +4 −1": the repos of a task, to pick the one the git panels show. Nothing outside a task.
struct TaskRepoTabs: View {
    @ObservedObject var review: ReviewModel
    let palette: Palette
    /// The graph's tabs step aside while the review is open, so one row picks for both.
    var yieldsToReview = false
    let pick: (String) -> Void

    var body: some View {
        if review.taskRepos.count > 1, !(yieldsToReview && review.isOpen) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(review.taskRepos, id: \.path) { repo in
                        Tab(name: (repo.path as NSString).lastPathComponent, stat: repo.stat,
                            selected: repo.path == review.root, palette: palette) { pick(repo.path) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            Rectangle().fill(palette.line).frame(height: 1)
        }
    }

    private struct Tab: View {
        let name: String
        let stat: Diff.Stat
        let selected: Bool
        let palette: Palette
        let pick: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if !stat.isEmpty { Counts(added: stat.added, removed: stat.removed, palette: palette) }
                }
                .foregroundStyle(selected || hovering ? palette.text : palette.muted)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? palette.raised : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onClickableHover { hovering = $0 }
        }
    }
}

/// A request's description and comments, above its files. It folds like a file.
private struct Conversation: View {
    let description: Forge.Discussion.Comment
    let comments: [Forge.Discussion.Comment]
    let palette: Palette
    let reveal: (String) -> Void

    @State private var folded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .foregroundStyle(palette.muted)
                    .frame(width: 12)
                Text("Conversation").font(.system(size: 12.5)).foregroundStyle(palette.text)
                Text(comments.count == 1 ? "1 comment" : "\(comments.count) comments")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? palette.raised : palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.line))
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onClickableHover { hovering = $0 }
            .onTapGesture { folded.toggle() }
            if !folded {
                CommentView(comment: description, empty: "No description.", palette: palette, reveal: reveal)
                ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                    CommentView(comment: comment, empty: "", palette: palette, reveal: reveal)
                }
            }
        }
        // Anyone can comment on a public request, so its links open only on the web, never a file or another app.
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
}

private struct CommentView: View {
    let comment: Forge.Discussion.Comment
    /// Shown in place of the text when there is none.
    let empty: String
    let palette: Palette
    /// Brings a commented file into view. Nil under the line itself, where the place goes without saying.
    let reveal: ((String) -> Void)?

    /// A comment starts as its first line, so a long thread stays easy to scan.
    @State private var expanded = false
    /// Whether the text needs more than its first line, which is when there is something to open.
    @State private var truncated = false

    private var blocks: [Markdown.Block] { Markdown.blocks(in: comment.text) }

    /// The first block's text, as the folded comment's one line.
    private var preview: Text { MarkdownBlocks.inline(blocks.first.map(Self.summary) ?? "") }

    private static func summary(_ block: Markdown.Block) -> String {
        switch block {
        case .heading(_, let text), .paragraph(let text): text
        case .code(_, let text): String(text.prefix { $0 != "\n" })
        case .quote(let blocks): blocks.first.map(summary) ?? ""
        case .list(_, _, let items): items.first?.blocks.first.map(summary) ?? ""
        case .table(let header, _): header.joined(separator: " · ")
        case .rule: ""
        }
    }

    private static let age: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(comment.author).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.text)
                if let verdict = comment.verdict {
                    Text(verdict).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(verdict == "approved" ? palette.added : palette.removed)
                }
                if let path = comment.path, let reveal {
                    Button { reveal(path) } label: {
                        Text((path as NSString).lastPathComponent + (comment.line.map { ":\($0)" } ?? ""))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .hoverTip("Show \(path) in the diff")
                }
                if let date = comment.date {
                    Text(Self.age.localizedString(for: date, relativeTo: Date())).font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                Spacer(minLength: 8)
                if truncated || expanded {
                    IconButton(symbol: expanded ? "chevron.up" : "chevron.down", help: expanded ? "Show less" : "Show all",
                               palette: palette) { expanded.toggle() }
                }
                if let url = comment.url {
                    IconButton(symbol: "arrow.up.right.square", help: "Open in the browser", palette: palette) { NSWorkspace.shared.open(url) }
                }
            }
            if comment.text.isEmpty {
                if !empty.isEmpty { Text(empty).font(.system(size: 12)).foregroundStyle(palette.muted) }
            } else {
                if expanded {
                    MarkdownBlocks(blocks: blocks, palette: palette)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.text)
                        .textSelection(.enabled)
                } else {
                    preview
                        .font(.system(size: 12))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .background {
                            // The first block is tried in the one line's space: when it doesn't fit, the second view is the one shown.
                            ViewThatFits(in: .vertical) {
                                preview.font(.system(size: 12)).hidden().onAppear { truncated = blocks.count > 1 || !blocks.allSatisfy(\.isText) }
                                Color.clear.onAppear { truncated = true }
                            }
                        }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.line))
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }
}

/// A comment's Markdown, read like the file pane's preview: headings, lists, code, quotes and tables, and bots' HTML.
private struct MarkdownBlocks: View {
    let blocks: [Markdown.Block]
    let palette: Palette

    private static let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(for: block) }
        }
    }

    @ViewBuilder private func view(for block: Markdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Self.inline(text).font(.system(size: level <= 2 ? 14 : 12.5, weight: .semibold))
        case .paragraph(let text):
            Self.inline(text).fixedSize(horizontal: false, vertical: true)
        case .code(_, let text):
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 5).fill(palette.surface))
        case .quote(let blocks):
            MarkdownBlocks(blocks: blocks, palette: palette)
                .foregroundStyle(palette.muted)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(palette.line).frame(width: 3) }
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.checked.map { $0 ? "☑" : "☐" } ?? (ordered ? "\(start + index)." : "•")).foregroundStyle(palette.muted)
                        MarkdownBlocks(blocks: item.blocks, palette: palette)
                    }
                }
            }
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { ForEach(Array(header.enumerated()), id: \.offset) { Self.inline($1).fontWeight(.semibold) } }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                    GridRow { ForEach(Array(cells.enumerated()), id: \.offset) { Self.inline($1) } }
                }
            }
        case .rule:
            Divider()
        }
    }

    static func inline(_ text: String) -> Text {
        let markdown = Markdown.inlineHTML(text)
        return Text((try? AttributedString(markdown: markdown, options: Self.options)) ?? AttributedString(markdown))
    }
}

/// Writes a comment on a line of the request, under that line. ⌘↩ sends it, Escape puts it away.
private struct LineComposer: View {
    @ObservedObject var review: ReviewModel
    let line: ReviewModel.LineRef
    let palette: Palette

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $review.draft)
                .font(.system(size: 12))
                .foregroundStyle(palette.text)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(minHeight: 56, maxHeight: 160)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.background))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.line))
            if let error = review.sendError {
                Text(error).font(.system(size: 11)).foregroundStyle(palette.removed).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(line.old ? "On removed line \(line.line)" : "On line \(line.line)").font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer(minLength: 8)
                ShipButton(title: "Cancel", busy: false, palette: palette) { review.cancelComment() }
                ShipButton(title: "Comment", busy: review.isSending, keys: "⌘↩", palette: palette) { review.sendComment() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.line))
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .onAppear { focused = true }
        .onExitCommand { review.cancelComment() }
    }
}

private extension Markdown.Block {
    /// A heading or a paragraph, which a folded comment's one line shows whole when it fits.
    var isText: Bool {
        switch self {
        case .heading, .paragraph: true
        default: false
        }
    }
}
