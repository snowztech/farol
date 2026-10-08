import AppKit
import FarolCore
import SwiftUI

/// The selected session's changes. The count in the title bar is always current. The full diff is only read while the panel is open.
final class ReviewModel: ObservableObject {
    enum Row: Identifiable {
        case header(Diff.File, collapsed: Bool)
        /// The file's lines, drawn by one text view so a selection can cross them.
        case body(Diff.File)
        case note(file: String, String)

        var id: String {
            switch self {
            case .header(let file, _): file.path
            case .body(let file): "\(file.path)#body"
            case .note(let file, _): "\(file)#note"
            }
        }
    }

    @Published private(set) var root: String?
    @Published private(set) var branch: String?
    @Published private(set) var scope = Diff.Scope.uncommitted
    /// Branches to compare with, the base one first.
    @Published private(set) var branches: [String] = []
    @Published private(set) var stat = Diff.Stat()
    /// What the title bar counts: your changes, even while the panel shows a commit.
    @Published private(set) var changes = Diff.Stat()
    var showsCommit: Bool { if case .commit = scope { true } else { false } }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var error: String?
    @Published var isOpen = false {
        didSet {
            guard isOpen != oldValue else { return }
            // A commit is only looked at while the panel is open. Closing it brings back what the title bar counts.
            if !isOpen, case .commit = scope, let root {
                chosenScope[root] = scopeBeforeCommit
                scope = scopeBeforeCommit ?? .uncommitted
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
    private var scopeBeforeCommit: Diff.Scope?

    private var files: [Diff.File] = []
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
            collapsed = []
            rows = []
            stat = Diff.Stat()
            changes = Diff.Stat()
            uncommittedPaths = []
            ahead = 0
            unpushed = 0
            forge = nil
            ignored = []
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
            let ignored = Files.ignored(in: root).map { $0 + "/" }
            let forge = Forge.detect(in: root)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root else { return }
                self.forge = forge
                self.ignored = ignored
                self.checkRequest()
            }
        }
    }

    /// Shows what one commit changed, as from the git graph.
    func show(commit hash: String, subject: String, file: String? = nil) {
        guard let root else { return }
        pendingFocus = file
        if case .commit = scope {} else { scopeBeforeCommit = chosenScope[root] ?? scope }
        commitSubject = subject
        chosenScope[root] = .commit(hash)
        scope = .commit(hash)
        refresh()
    }

    /// Goes back from a commit to the changes shown before it. False when no commit is shown.
    func leaveCommit() -> Bool {
        guard isOpen, case .commit = scope, let root else { return false }
        chosenScope[root] = scopeBeforeCommit
        scope = scopeBeforeCommit ?? .uncommitted
        refresh()
        return true
    }

    func choose(_ scope: Diff.Scope) {
        guard let root, scope != self.scope else { return }
        chosenScope[root] = scope
        self.scope = scope
        refresh()
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
        if case .commit = scope { return nil }
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
                if let failure { failed(failure.0, failure.1) } else if let link { NSWorkspace.shared.open(link) }
                self.refresh()
                if let created, self.root == root, self.branch == branch { self.request = created }
                if next != .nothing, failure == nil { self.checksDue = Date() + 60 }
                self.checkRequest()
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
    func checkRequest() {
        guard let root, let branch, let forge, !isOnBaseBranch else { return }
        DispatchQueue.global(qos: .utility).async {
            let state = forge.request(for: branch, in: root)
            var checks: [Forge.Check] = []
            if case .open = state { checks = forge.checks(for: branch, in: root) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root, self.branch == branch else { return }
                self.request = state
                self.checks = checks
                // Nothing local says a pipeline moved on, so the forge is asked again until it settles.
                self.poll?.cancel()
                guard self.isOpen, checks.contains(where: { $0.state == .running }) || Date() < self.checksDue else { return }
                let poll = DispatchWorkItem { [weak self] in self?.checkRequest() }
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

    /// Reads the counts, and the whole diff when the panel is open, off the main thread.
    func refresh() {
        pending?.cancel()
        guard let root, !scopePending else { return }
        let scope = scope, withFiles = isOpen, base = branches.first, branch = branch
        let yours = showsCommit ? scopeBeforeCommit ?? .uncommitted : scope
        DispatchQueue.global(qos: .userInitiated).async {
            // In the order you see them: the open panel's diff, the title bar's counts, then what only feeds the buttons.
            let stat = Result { try Diff.stat(in: root, scope) }
            let files = withFiles ? Result { try Diff.files(in: root, scope) } : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root, self.scope == scope else { return }
                self.stat = (try? stat.get()) ?? Diff.Stat()
                self.error = (try? files?.get()) == nil && files != nil ? "Couldn't read the changes." : nil
                if let files = try? files?.get() {
                    let known = Set(self.files.map(\.path))
                    for file in files where !known.contains(file.path) && file.added + file.removed > Self.foldedAbove {
                        self.collapsed.insert(file.path)
                    }
                    self.files = files
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
            let changes = yours == scope ? stat : Result { try Diff.stat(in: root, yours) }
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
                    self.checkRequest()
                }
                self.unpushed = unpushed
            }
        }
    }

    /// Agents write in bursts, so changes wait a moment and refresh once.
    private func changed(_ paths: [String]) {
        let relevant = paths.contains { path in
            if path.contains("/.git/") { return path.hasSuffix("/.git/index") || path.hasSuffix("/.git/HEAD") }
            return !ignored.contains { path.hasPrefix($0) }
        }
        guard relevant else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func rebuild() {
        var rows: [Row] = []
        for file in files {
            let folded = collapsed.contains(file.path)
            rows.append(.header(file, collapsed: folded))
            if folded { continue }
            if file.isBinary { rows.append(.note(file: file.path, "Binary file")) }
            if !file.hunks.isEmpty { rows.append(.body(file)) }
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
    let close: () -> Void
    let resize: (CGFloat) -> Void

    @State private var dragStart: CGFloat?

    var body: some View {
        let p = state.palette
        VStack(alignment: .leading, spacing: 0) {
            header(p)
            HStack(spacing: 8) {
                ScopeMenu(review: review, palette: p)
                Spacer(minLength: 0)
                // The slot holds the next step: commit what's there, then open the request for the branch.
                // Where there is no request to open, as on main or once the branch has one, the next step is a push.
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
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(review.rows) { row(for: $0, p) }
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

    /// Looking at one commit, the working tree plays no part, so there is nothing to offer a commit for.
    private var isCommit: Bool { review.showsCommit }

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
                       open: { review.root.map { open(($0 as NSString).appendingPathComponent(file.path), file.firstChange) } })
        case .body(let file):
            DiffText(file: file, colors: p.diff, syntax: p.code).padding(.horizontal, 8)
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
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        if case .commit(let hash) = review.scope {
            let subject = review.commitSubject.map { ": " + ($0.count > 40 ? $0.prefix(40) + "…" : $0) } ?? ""
            menu.addItem(item("Commit \(hash.prefix(7))" + subject, review.scope))
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
            Text("+\(added)").foregroundStyle(palette.added)
            Text("−\(removed)").foregroundStyle(palette.removed)
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
    let open: () -> Void

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
            (Text(folder).foregroundColor(palette.muted) + Text(name).foregroundColor(ticked == false ? palette.muted : palette.text))
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.head)
            if let status { Text(status).font(.system(size: 11)).foregroundStyle(palette.muted) }
            Counts(added: file.added, removed: file.removed, palette: palette)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.line))
            Spacer(minLength: 8)
            IconButton(symbol: "square.on.square", help: "Copy path", palette: palette) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            if file.status != .deleted {
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

