import AppKit
import FarolCore
import SwiftUI

/// The selected session's commit graph. Git is only asked while the panel is open.
final class GraphModel: ObservableObject {
    @Published private(set) var root: String?
    /// The branch checked out in the session.
    @Published private(set) var current: String?
    /// Every branch, or only what the checked out one leads back to.
    @Published private(set) var showsAll = true
    @Published private(set) var local: [String] = []
    @Published private(set) var remote: [String] = []
    /// Each local branch's upstream, for the Update item.
    @Published private(set) var upstreams: [String: History.Upstream] = [:]
    @Published private(set) var fetching = false
    /// The open pull requests, by branch, for the button next to each. Empty without gh or glab.
    @Published private(set) var requests: [String: Forge.Request] = [:]
    /// The branch under the mouse in the list, so the history can light up the commit it points to.
    @Published var hoveredBranch: String?
    @Published private(set) var rows: [History.Row] = []
    @Published private(set) var error: String?
    /// The commit clicked in the history, and what it changed, for the pane under it.
    @Published private(set) var selected: History.Commit?
    @Published private(set) var selectedFiles: [Diff.File]?

    /// Your choice per checkout, so switching sessions doesn't reset it.
    private var onlyCurrent: Set<String> = []
    /// Lets the session pick up the new branch right away rather than at the next prompt.
    var onGitChange: (() -> Void)?
    /// Runs a command that needs you, like an interactive rebase, in a new pane of the session.
    var onRunInTerminal: ((String) -> Void)?
    /// Opens the review panel on a commit.
    var onShowInReview: ((History.Commit, _ file: String?) -> Void)?
    private var watcher: FolderWatcher?
    private var pending: DispatchWorkItem?

    /// Follows another checkout, or stops when `root` is nil, as when the panel is closed.
    func show(_ root: String?, current: String?) {
        guard root != self.root || current != self.current || (root != nil && watcher == nil) else { return }
        let rootChanged = root != self.root
        self.root = root
        self.current = current
        if rootChanged {
            watcher = nil
            rows = []
            error = nil
            selected = nil
            selectedFiles = nil
            requests = [:]
        }
        guard let root else {
            watcher = nil
            return
        }
        // Commits and branch moves land in the repo's own .git, which a worktree only points to.
        if watcher == nil, let repo = Git.repoRoot(of: root) {
            watcher = FolderWatcher((repo as NSString).appendingPathComponent(".git")) { [weak self] in self?.changed($0) }
        }
        reload()
        if rootChanged { loadRequests() }
    }

    func show(all: Bool) {
        guard let root, all != showsAll else { return }
        if all { onlyCurrent.remove(root) } else { onlyCurrent.insert(root) }
        showsAll = all
        reload()
    }

    /// Switches the session's checkout to `branch`. Git refuses when that would lose uncommitted work, and `failed` gets its message.
    func checkout(_ branch: String, remote: Bool, failed: @escaping (String) -> Void) {
        guard remote || branch != current else { return }
        run(failed) { try History.checkout(branch, remote: remote, in: $0) }
    }

    func checkout(_ commit: History.Commit, failed: @escaping (String) -> Void) {
        run(failed) { try History.checkout(commit, in: $0) }
    }

    /// Clicking the selected commit again closes the pane.
    func select(_ commit: History.Commit?) {
        guard commit?.hash != selected?.hash else {
            selected = nil
            return selectedFiles = nil
        }
        selected = commit
        selectedFiles = nil
        guard let root, let commit else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let files = (try? Diff.files(in: root, .commit(commit.hash))) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selected?.hash == commit.hash else { return }
                self.selectedFiles = files
            }
        }
    }

    func createBranch(_ name: String, from start: String, failed: @escaping (String) -> Void) {
        run(failed) { try History.createBranch(name, from: start, in: $0) }
    }

    func delete(_ branch: String, force: Bool, failed: @escaping (String) -> Void) {
        run(failed) { try History.deleteBranch(branch, force: force, in: $0) }
    }

    func deleteRemote(_ branch: String, failed: @escaping (String) -> Void) {
        run(failed) { try History.deleteRemoteBranch(branch, in: $0) }
    }

    func fetch(failed: @escaping (String) -> Void) {
        guard !fetching else { return }
        fetching = true
        run(failed, then: { [weak self] in
            self?.fetching = false
            self?.loadRequests()
        }) { try History.fetch(in: $0) }
    }

    func update(_ branch: String, failed: @escaping (String) -> Void) {
        let current = branch == current
        run(failed) { try History.update(branch, current: current, in: $0) }
    }

    func push(_ branch: String, failed: @escaping (String) -> Void) {
        run(failed, then: { [weak self] in self?.loadRequests() }) { try History.push(branch, in: $0) }
    }

    /// Asks the forge, so only when a request may have changed: another checkout, the panel reopened, a fetch or a push.
    private func loadRequests() {
        guard let root else { return }
        DispatchQueue.global(qos: .utility).async {
            let requests = Forge.detect(in: root)?.openRequests(in: root) ?? [:]
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root else { return }
                self.requests = requests
            }
        }
    }

    func rebase(onto base: String, interactive: Bool, failed: @escaping (String) -> Void) {
        if interactive { return onRunInTerminal?(History.interactiveRebaseCommand(onto: base)) ?? () }
        run(failed) { try History.rebase(onto: base, in: $0) }
    }

    func merge(_ branch: String, noFastForward: Bool, failed: @escaping (String) -> Void) {
        run(failed) { try History.merge(branch, noFastForward: noFastForward, in: $0) }
    }

    func revert(_ commit: History.Commit, failed: @escaping (String) -> Void) {
        run(failed) { try History.revert(commit, in: $0) }
    }

    func cherryPick(_ commit: History.Commit, failed: @escaping (String) -> Void) {
        run(failed) { try History.cherryPick(commit, in: $0) }
    }

    private func run(_ failed: @escaping (String) -> Void, then done: (() -> Void)? = nil, _ work: @escaping (String) throws -> Void) {
        guard let root else { return done?() ?? () }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(root) }
            DispatchQueue.main.async { [weak self] in
                done?()
                if case .failure(let error) = result { failed(String(describing: error)) }
                self?.onGitChange?()
                self?.reload()
            }
        }
    }

    private func reload() {
        pending?.cancel()
        guard let root else { return }
        let all = !onlyCurrent.contains(root)
        let current = current
        showsAll = all
        DispatchQueue.global(qos: .userInitiated).async {
            let branches = History.branches(in: root)
            let upstreams = History.upstreams(in: root)
            let commits = Result { try History.commits(in: root, branch: all ? nil : "HEAD") }
            let oneSided = all ? History.oneSided(upstreams, in: root) : History.oneSided(upstreams.filter { $0.key == current }, in: root)
            let rows = (try? commits.get()).map { History.graph($0, oneSided: oneSided) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root else { return }
                self.local = branches.local
                self.remote = branches.remote
                self.upstreams = upstreams
                self.rows = rows ?? []
                self.error = rows == nil ? "Couldn't read the history." : nil
            }
        }
    }

    /// Git writes many files for one commit or fetch, so changes wait a moment and reload once.
    private func changed(_ paths: [String]) {
        let relevant = paths.contains { $0.hasSuffix("/HEAD") || $0.contains("/refs/") || $0.hasSuffix("/packed-refs") }
        guard relevant else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

struct GraphPanel: View {
    static let defaultWidth: CGFloat = 420

    @ObservedObject var graph: GraphModel
    @ObservedObject var state: WindowState
    let resize: (CGFloat) -> Void

    @State private var dragStart: CGFloat?
    /// One search for both lists: branches by name, commits by message, author, hash or branch.
    @State private var query = ""
    /// Set once a commit is clicked, so the arrow keys go to the history.
    @FocusState private var walking: Bool

    var body: some View {
        let p = state.palette
        VStack(alignment: .leading, spacing: 0) {
            if graph.root != nil, graph.error == nil {
                BranchList(graph: graph, query: $query, colors: branchColors, palette: p)
                Rectangle().fill(p.line).frame(height: 1)
                historyHeader(p)
            }
            if let error = graph.error {
                message(error, p)
            } else if graph.rows.isEmpty {
                message(graph.root == nil ? "Not a git repository." : "No commits.", p)
            } else {
                let lanes = min(graph.rows.map(\.width).max() ?? 1, CommitRow.maxLanes)
                let rows = matchingRows
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                if rows.isEmpty {
                                    Text("No commit matches.")
                                        .font(.system(size: 12))
                                        .foregroundStyle(p.muted)
                                        .frame(maxWidth: .infinity, minHeight: 40)
                                }
                                ForEach(rows, id: \.commit.hash) { row in
                                    // Lines between commits that aren't neighbors anymore would mislead, so a search shows the dots only.
                                    CommitRow(row: row, lanes: lanes, width: geometry.size.width - 12,
                                              showsLines: searchText.isEmpty, selected: row.commit.hash == graph.selected?.hash,
                                              highlighted: graph.hoveredBranch.map(row.commit.points) ?? false,
                                              palette: p, current: graph.current, upstreams: graph.upstreams,
                                              select: {
                                                  graph.select(row.commit)
                                                  walking = true
                                              },
                                              review: {
                                                  // Keeps the files pane on this commit too, instead of toggling it off.
                                                  if graph.selected?.hash != row.commit.hash { graph.select(row.commit) }
                                                  graph.onShowInReview?(row.commit, nil)
                                              },
                                              cherryPick: { graph.cherryPick(row.commit, failed: gitError("Cherry-pick stopped")) },
                                              revert: { revert(row.commit) },
                                              rebase: { rebase(onto: row.commit) },
                                              rebaseInteractively: {
                                                  graph.rebase(onto: row.commit.hash, interactive: true, failed: gitError("Couldn't rebase"))
                                              },
                                              newBranch: {
                                                  askBranchName(from: row.commit.shortHash, suggested: "") { name in
                                                      graph.createBranch(name, from: row.commit.hash, failed: gitError("Couldn't create the branch"))
                                                  }
                                              }) {
                                        graph.checkout(row.commit, failed: gitError("Couldn't check out"))
                                    }
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)
                        }
                        .scrollIndicators(.hidden)
                        // Arrows walk the history from the selected commit, and Return opens its changes.
                        // Takes the keyboard like a text field does, on a click, so the terminal keeps it until then.
                        .focusable(interactions: .edit)
                        .focusEffectDisabled()
                        .focused($walking)
                        .onKeyPress(.downArrow) { move(1, in: rows, proxy) }
                        .onKeyPress(.upArrow) { move(-1, in: rows, proxy) }
                        .onKeyPress(.return) {
                            guard let commit = graph.selected else { return .ignored }
                            graph.onShowInReview?(commit, nil)
                            return .handled
                        }
                    }
                }
                if let commit = graph.selected {
                    Rectangle().fill(p.line).frame(height: 1)
                    CommitPane(commit: commit, files: graph.selectedFiles, palette: p,
                               review: { graph.onShowInReview?(commit, $0) }, close: { graph.select(nil) })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(p.surface)
        .overlay(alignment: .leading) { edge(p) }
    }

    private func rebase(onto commit: History.Commit) {
        let branch = graph.current ?? "HEAD"
        confirm("Rebase \(branch) onto \(commit.shortHash)?",
                "Your commits on \(branch) are replayed on top of \u{201C}\(commit.subject)\u{201D}. If they conflict, git stops and the terminal shows how to go on.",
                button: "Rebase") {
            graph.rebase(onto: commit.hash, interactive: false, failed: gitError("Rebase stopped"))
        }
    }

    private func revert(_ commit: History.Commit) {
        let branch = graph.current ?? "HEAD"
        let merge = commit.parents.count > 1 ? " It's a merge, so everything the merged branch brought in is undone." : ""
        confirm("Revert \(commit.shortHash) on \(branch)?",
                "A new commit undoes \u{201C}\(commit.subject)\u{201D}. The original stays in the history, so this is safe on a pushed branch."
                    + merge + " If it conflicts, git stops and the terminal shows how to go on.",
                button: "Revert") {
            graph.revert(commit, failed: gitError("Revert stopped"))
        }
    }

    private var searchText: String { query.trimmingCharacters(in: .whitespaces) }

    /// Selects the commit above or below the selected one and keeps it in view.
    private func move(_ step: Int, in rows: [History.Row], _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let index = rows.firstIndex(where: { $0.commit.hash == graph.selected?.hash }),
              rows.indices.contains(index + step) else { return .ignored }
        let commit = rows[index + step].commit
        graph.select(commit)
        proxy.scrollTo(commit.hash)
        return .handled
    }

    private var matchingRows: [History.Row] {
        let text = searchText
        guard !text.isEmpty else { return graph.rows }
        return graph.rows.filter { row in
            let commit = row.commit
            return commit.hash.hasPrefix(text.lowercased())
                || ([commit.subject, commit.author] + commit.refs).contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    /// Each branch's dot takes the color of its line in the graph, so the list and the history read together.
    private var branchColors: [String: Int] {
        var colors: [String: Int] = [:]
        for row in graph.rows {
            for ref in row.commit.refs {
                let name = ref.hasPrefix("HEAD -> ") ? String(ref.dropFirst("HEAD -> ".count)) : ref
                if colors[name] == nil { colors[name] = row.color }
            }
        }
        return colors
    }

    /// "HISTORY", and whether it covers every branch or only the checked out one.
    private func historyHeader(_ p: Palette) -> some View {
        HStack(spacing: 2) {
            SectionTitle(text: "History", palette: p)
            if !searchText.isEmpty {
                let count = matchingRows.count
                Text("\(count) \(count == 1 ? "match" : "matches")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(p.muted)
                    .padding(.leading, 6)
            }
            Spacer()
            if graph.fetching {
                ProgressView().controlSize(.mini).frame(width: 26, height: 20)
            } else {
                IconButton(symbol: "arrow.clockwise", help: "Fetch from the server", palette: p) {
                    graph.fetch(failed: gitError("Couldn't fetch"))
                }
            }
            ForEach([("All", true), ("Current", false)], id: \.0) { title, all in
                Button { graph.show(all: all) } label: {
                    Text(title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(graph.showsAll == all ? p.text : p.muted)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(graph.showsAll == all ? p.raised : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverTip(all ? "Show every branch" : "Show only the checked out branch")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 30)
    }

    /// The line between the terminal and the panel, wide enough to grab and drag, like the review panel's.
    private func edge(_ p: Palette) -> some View {
        Rectangle().fill(p.boxed ? .clear : p.line).frame(width: 1)
            .frame(width: 7, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? state.graphWidth
                    dragStart = start
                    resize(start - drag.translation.width)
                }
                .onEnded { _ in dragStart = nil })
    }

    private func message(_ text: String, _ p: Palette) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(p.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SectionTitle: View {
    let text: String
    let palette: Palette

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.muted)
    }
}

/// Every branch, the checked out one first. A click checks it out. A remote branch with a local twin is left out, since it's the same branch.
private struct BranchList: View {
    /// Room for about eight branches before the list scrolls, so the history keeps most of the panel.
    static let maxHeight: CGFloat = 8 * BranchRow.height + 8

    @ObservedObject var graph: GraphModel
    @Binding var query: String
    let colors: [String: Int]
    let palette: Palette

    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if searching {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(palette.muted)
                    TextField("Search branches and commits", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.text)
                        .focused($focused)
                        .onExitCommand(perform: closeSearch)
                    CloseButton(help: "Stop searching", palette: palette, action: closeSearch)
                } else {
                    SectionTitle(text: "Branches", palette: palette)
                    Spacer()
                    IconButton(symbol: "magnifyingglass", help: "Search branches and commits", palette: palette) {
                        searching = true
                        focused = true
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 30)
            let entries = self.entries
            ScrollView {
                LazyVStack(spacing: 0) {
                    if graph.current == nil, query.isEmpty {
                        Text("Detached HEAD")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .padding(.horizontal, 22)
                            .frame(maxWidth: .infinity, minHeight: BranchRow.height, alignment: .leading)
                    }
                    ForEach(entries, id: \.name) { entry in
                        let current = !entry.remote && entry.name == graph.current
                        BranchRow(name: entry.name, remote: entry.remote, current: current,
                                  upstream: entry.remote ? nil : graph.upstreams[entry.name],
                                  request: graph.requests[entry.remote ? String(entry.name.drop { $0 != "/" }.dropFirst()) : entry.name],
                                  color: colors[entry.name].map { palette.lanes[$0 % palette.lanes.count] } ?? palette.muted,
                                  palette: palette,
                                  update: { graph.update(entry.name, failed: gitError("Couldn't update \(entry.name)")) },
                                  push: { graph.push(entry.name, failed: gitError("Couldn't push \(entry.name)")) },
                                  hover: { inside in
                                      if inside { graph.hoveredBranch = entry.name } else if graph.hoveredBranch == entry.name { graph.hoveredBranch = nil }
                                  }) {
                            graph.checkout(entry.name, remote: entry.remote, failed: gitError("Couldn't check out"))
                        }
                        .contextMenu { menu(for: entry.name, remote: entry.remote, current: current) }
                    }
                    if entries.isEmpty {
                        Text("No branch matches.")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.muted)
                            .frame(maxWidth: .infinity, minHeight: BranchRow.height)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .frame(height: min(CGFloat(max(entries.count, 1) + (graph.current == nil ? 1 : 0)) * BranchRow.height + 8, Self.maxHeight))
        }
    }

    private var entries: [(name: String, remote: Bool)] {
        let local = graph.current.map { current in [current] + graph.local.filter { $0 != current } } ?? graph.local
        let localNames = Set(local)
        let remoteOnly = graph.remote.filter { remote in
            guard let slash = remote.firstIndex(of: "/") else { return true }
            return !localNames.contains(String(remote[remote.index(after: slash)...]))
        }
        let all = local.map { ($0, false) } + remoteOnly.map { ($0, true) }
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? all : all.filter { $0.0.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder private func menu(for branch: String, remote: Bool, current: Bool) -> some View {
        let here = graph.current ?? "HEAD"
        Button(remote ? "Check Out as Local Branch" : "Check Out") { graph.checkout(branch, remote: remote, failed: gitError("Couldn't check out")) }
            .disabled(current)
        if !remote, let upstream = graph.upstreams[branch] {
            Button("Update from \(menuName(upstream.name))") { graph.update(branch, failed: gitError("Couldn't update \(branch)")) }
                .disabled(upstream.behind == 0)
        }
        Button("Copy Branch Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(branch, forType: .string)
        }
        Button("Create Branch from This One…") {
            let suggested = remote ? String(branch.drop { $0 != "/" }.dropFirst()) + "-copy" : branch + "-copy"
            askBranchName(from: branch, suggested: suggested) { name in
                graph.createBranch(name, from: branch, failed: gitError("Couldn't create the branch"))
            }
        }
        Divider()
        Button("Merge \u{201C}\(menuName(branch))\u{201D} into \u{201C}\(menuName(here))\u{201D}") {
            graph.merge(branch, noFastForward: false, failed: gitError("Merge stopped"))
        }
        .disabled(current)
        Button("Merge \u{201C}\(menuName(branch))\u{201D} into \u{201C}\(menuName(here))\u{201D} (No Fast-Forward)") {
            graph.merge(branch, noFastForward: true, failed: gitError("Merge stopped"))
        }
        .disabled(current)
        Divider()
        Button("Rebase \u{201C}\(menuName(here))\u{201D} onto \u{201C}\(menuName(branch))\u{201D}…") {
            confirm("Rebase \(here) onto \(branch)?",
                    "Your commits on \(here) are replayed on top of \(branch). If they conflict, git stops and the terminal shows how to go on.",
                    button: "Rebase") {
                graph.rebase(onto: branch, interactive: false, failed: gitError("Rebase stopped"))
            }
        }
        .disabled(current)
        Button("Interactive Rebase \u{201C}\(menuName(here))\u{201D} onto \u{201C}\(menuName(branch))\u{201D}…") {
            graph.rebase(onto: branch, interactive: true, failed: gitError("Couldn't rebase"))
        }
        .disabled(current)
        Divider()
        // A local branch and its twin on the server can go separately, since deleting either doesn't touch the other.
        let twin = remote ? branch : graph.remote.first { $0.drop { $0 != "/" }.dropFirst() == branch }
        if !remote {
            Button("Delete Local Branch…") { delete(branch) }
                .disabled(current)
        }
        if let twin {
            Button("Delete Remote Branch (\(twin.prefix { $0 != "/" }))…") { deleteRemote(twin) }
        }
    }

    /// A branch that isn't merged anywhere asks a second time, since deleting it loses its commits.
    private func delete(_ branch: String) {
        confirm("Delete the local branch \(branch)?", "Only your copy goes. The branch on the server, if there is one, stays.",
                button: "Delete", destructive: true) {
            graph.delete(branch, force: false) { message in
                guard message.contains("not fully merged") else { return gitError("Couldn't delete the branch")(message) }
                confirm("\(branch) isn't merged. Delete it anyway?",
                        "Commits that are only on \(branch) will be lost.", button: "Delete Anyway", destructive: true) {
                    graph.delete(branch, force: true, failed: gitError("Couldn't delete the branch"))
                }
            }
        }
    }

    private func deleteRemote(_ branch: String) {
        confirm("Delete \(branch) on the server?",
                "It's removed for everyone who uses this remote, and any open pull request from it closes. Your local branch stays.",
                button: "Delete on Server", destructive: true) {
            graph.deleteRemote(branch, failed: gitError("Couldn't delete the remote branch"))
        }
    }

    private func closeSearch() {
        query = ""
        searching = false
    }
}

private struct BranchRow: View {
    static let height: CGFloat = 24

    let name: String
    let remote: Bool
    let current: Bool
    var upstream: History.Upstream?
    var request: Forge.Request?
    let color: Color
    let palette: Palette
    var update: () -> Void = {}
    var push: () -> Void = {}
    var hover: (Bool) -> Void = { _ in }
    let checkout: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            // "remote" already says where it lives, so origin/ would only repeat it.
            Text(remote ? String(name.drop { $0 != "/" }.dropFirst()) : name)
                .font(.system(size: 12, weight: current ? .semibold : .regular))
                .foregroundStyle(remote ? palette.muted : palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if remote {
                Text("remote").font(.system(size: 10)).foregroundStyle(palette.muted).fixedSize()
            }
            Spacer(minLength: 4)
            if let upstream, upstream.ahead + upstream.behind > 0 {
                HStack(spacing: 2) {
                    if upstream.behind > 0 {
                        DriftButton(symbol: "arrow.down", count: upstream.behind, label: "Update", showsLabel: hovering, color: palette.pull,
                                    help: "Update from \(upstream.name)", palette: palette, action: update)
                    }
                    if upstream.ahead > 0 {
                        DriftButton(symbol: "arrow.up", count: upstream.ahead, label: "Push", showsLabel: hovering, color: palette.added,
                                    help: "Push to \(upstream.name)", palette: palette, action: push)
                    }
                }
            }
            if let request {
                PullRequestButton(request: request, palette: palette)
            }
            if current {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.text)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 5).fill(current ? palette.raised : hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onClickableHover {
            hovering = $0
            hover($0)
        }
        .onTapGesture { if !current { checkout() } }
        .hoverTip(([current ? "Checked out" : remote ? "Check out \(name) as a local branch" : "Check out \(name)"] + drift)
            .joined(separator: "\n"))
    }


    private var drift: [String] {
        guard let upstream else { return [] }
        return [upstream.behind > 0 ? "\(upstream.behind) to pull from \(upstream.name)" : nil,
                upstream.ahead > 0 ? "\(upstream.ahead) to push to \(upstream.name)" : nil].compactMap { $0 }
    }
}

/// Opens the branch's pull request in the browser.
private struct PullRequestButton: View {
    let request: Forge.Request
    let palette: Palette

    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(request.url) } label: {
            HStack(spacing: 3) {
                PullRequestGlyph()
                    .stroke(style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
                    .frame(width: 10, height: 10)
                Text("#\(request.number)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(hovering ? palette.text : palette.muted)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? palette.text.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onClickableHover { hovering = $0 }
        .hoverTip("#\(request.number) \(request.title)\nOpen in the browser")
    }
}

/// A pull request's mark: two commits on a branch, and a line from a third coming back into it.
private struct PullRequestGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        // Drawn on a 16 point grid, then scaled to the frame.
        let scale = min(rect.width, rect.height) / 16
        let point = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale) }
        var path = Path()
        for (x, y) in [(4.0, 3.5), (4.0, 12.5), (12.0, 12.5)] {
            path.addEllipse(in: CGRect(x: rect.minX + (x - 1.8) * scale, y: rect.minY + (y - 1.8) * scale,
                                       width: 3.6 * scale, height: 3.6 * scale))
        }
        path.move(to: point(4, 5.3))
        path.addLine(to: point(4, 10.7))
        path.move(to: point(12, 10.7))
        path.addLine(to: point(12, 6.5))
        path.addQuadCurve(to: point(10, 4.5), control: point(12, 4.5))
        path.addLine(to: point(7.5, 4.5))
        path.move(to: point(9, 3))
        path.addLine(to: point(7.5, 4.5))
        path.addLine(to: point(9, 6))
        return path
    }
}

/// Commits to pull or push and the action that takes care of them. The action is named while the row is hovered.
private struct DriftButton: View {
    let symbol: String
    let count: Int
    let label: String
    let showsLabel: Bool
    let color: Color
    let help: String
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                Text("\(count)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                if showsLabel { Text(label).font(.system(size: 10.5, weight: .medium)) }
            }
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? palette.text.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onClickableHover { hovering = $0 }
        .hoverTip(help)
    }
}

private struct CommitRow: View {
    /// Past this many lanes the graph is clipped, so a busy repo can't push the subjects out of the panel.
    static let maxLanes = 8
    static let laneWidth: CGFloat = 12
    static let height: CGFloat = 24
    static let spacing: CGFloat = 6
    /// Fixed widths, so the columns line up and a long name can't push the row wider than the panel.
    static let authorWidth: CGFloat = 90
    static let hashWidth: CGFloat = 52
    static let dateWidth: CGFloat = 64
    /// What the subject keeps in a narrow panel. Under it the author goes, then the hash. Both stay in the row's tooltip.
    static let subjectWidth: CGFloat = 140

    static func graphWidth(_ lanes: Int) -> CGFloat { CGFloat(lanes) * laneWidth + 4 }

    let row: History.Row
    let lanes: Int
    /// The width the row has, to drop columns that no longer fit.
    let width: CGFloat
    var showsLines = true
    var selected = false
    /// Set while the mouse is on a branch that points here.
    var highlighted = false
    let palette: Palette
    /// The checked out branch, named in the cherry-pick item.
    var current: String?
    var upstreams: [String: History.Upstream] = [:]
    var select: () -> Void = {}
    var review: () -> Void = {}
    var cherryPick: () -> Void = {}
    var revert: () -> Void = {}
    var rebase: () -> Void = {}
    var rebaseInteractively: () -> Void = {}
    var newBranch: () -> Void = {}
    let checkout: () -> Void

    @State private var hovering = false
    @State private var hoveringHash = false
    @State private var copied = false

    /// What is left for the author and the hash once the graph, the subject and the date have theirs.
    private var room: CGFloat {
        width - Self.graphWidth(lanes) - Self.subjectWidth - Self.dateWidth - 3 * Self.spacing - 10
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            lines
                .frame(width: Self.graphWidth(lanes), height: Self.height)
                .clipped()
            Text(row.commit.subject)
                // Bold where HEAD is, so you see where a checkout landed even without a branch.
                .font(.system(size: 12, weight: isHead ? .semibold : .regular))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if let drift {
                Text(drift.counts)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(palette.muted)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            if room >= Self.authorWidth + Self.hashWidth + 2 * Self.spacing {
                Text(row.commit.author)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: Self.authorWidth, alignment: .leading)
                    .hoverTip(row.commit.email.isEmpty ? row.commit.author : "\(row.commit.author) <\(row.commit.email)>")
            }
            if room >= Self.hashWidth + Self.spacing {
                Text(copied ? "Copied" : row.commit.shortHash)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(copied ? palette.text : hoveringHash ? palette.text : palette.muted.opacity(0.8))
                    .underline(hoveringHash && !copied)
                    .lineLimit(1)
                    .frame(width: Self.hashWidth, alignment: .leading)
                    .contentShape(Rectangle())
                    .onClickableHover { hoveringHash = $0 }
                    .onTapGesture(perform: copyHash)
                    .hoverTip("Copy \(row.commit.hash)")
            }
            Text(Self.age.localizedString(for: row.commit.date, relativeTo: Date()))
                .font(.system(size: 11))
                .foregroundStyle(palette.muted)
                .lineLimit(1)
                .frame(width: Self.dateWidth, alignment: .trailing)
        }
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected || highlighted ? palette.raised : hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: review)
        .onTapGesture(perform: select)
        .hoverTip(([row.commit.shortHash + "  " + row.commit.author, row.commit.subject] + refs.flatMap(\.names)
            + (drift.map { [driftTip($0.branch, $0.upstream)] } ?? []) + ["Double-click to review the changes"]).joined(separator: "\n"))
        .contextMenu {
            // Says where a checkout lands: the branch pointing here, or the bare commit.
            Button(localBranch.map { "Check Out \u{201C}\(menuName($0))\u{201D}" } ?? "Check Out Commit (Detached)", action: checkout)
                .disabled(isHead)
            Button("Create Branch at This Commit…", action: newBranch)
            Divider()
            // A merge has two parents, and picking one needs a choice this menu can't offer.
            Button("Cherry-Pick into Current Branch", action: cherryPick)
                .disabled(isHead || row.commit.parents.count > 1)
            Button("Revert This Commit…", action: revert)
            Divider()
            // Rebasing onto the commit you're on would change nothing.
            Button("Rebase \u{201C}\(menuName(current ?? "HEAD"))\u{201D} onto This Commit…", action: rebase)
                .disabled(isHead)
            Button("Interactive Rebase \u{201C}\(menuName(current ?? "HEAD"))\u{201D} from This Commit…", action: rebaseInteractively)
                .disabled(isHead)
            Divider()
            Button("Copy Commit Hash") { copy(row.commit.hash) }
            Button("Copy Commit Title") { copy(row.commit.subject) }
        }
    }

    /// The lines from the children above and to the parents below, then the commit's dot on top.
    private var lines: some View {
        Canvas { context, size in
            let middle = size.height / 2
            func x(_ lane: Int) -> CGFloat { CGFloat(lane) * Self.laneWidth + Self.laneWidth / 2 + 2 }
            func stroke(_ edge: History.Edge, from y0: CGFloat, to y1: CGFloat, tone: Int, dashed: Bool) {
                var path = Path()
                path.move(to: CGPoint(x: x(edge.from), y: y0))
                if edge.from == edge.to {
                    path.addLine(to: CGPoint(x: x(edge.to), y: y1))
                } else {
                    let bend = (y0 + y1) / 2
                    path.addCurve(to: CGPoint(x: x(edge.to), y: y1),
                                  control1: CGPoint(x: x(edge.from), y: bend), control2: CGPoint(x: x(edge.to), y: bend))
                }
                // Half a row is 12 points, so the dashes run on unbroken from one row to the next.
                context.stroke(path, with: .color(color(tone)), style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 3] : []))
            }
            if showsLines {
                for edge in row.top {
                    stroke(edge, from: 0, to: middle, tone: row.colorsAbove[edge.from], dashed: row.dashedAbove[edge.from])
                }
                for edge in row.bottom {
                    // The commit's own lines follow the commit. The lanes passing by keep whatever they lead from.
                    let dashed = edge.from == row.column ? row.oneSided : row.dashedBelow[edge.to]
                    stroke(edge, from: middle, to: size.height, tone: row.colorsBelow[edge.to], dashed: dashed)
                }
            }
            let tint = color(row.color)
            if isHead {
                // HEAD is a ring, so you find where you are at a glance.
                let ring = CGRect(x: x(row.column) - 5, y: middle - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: ring), with: .color(palette.surface))
                context.stroke(Path(ellipseIn: ring), with: .color(tint), lineWidth: 2)
            } else {
                context.fill(Path(ellipseIn: CGRect(x: x(row.column) - 4, y: middle - 4, width: 8, height: 8)), with: .color(tint))
            }
        }
    }

    private func color(_ tone: Int) -> Color { palette.lanes[tone % palette.lanes.count] }

    /// The local branch a checkout switches to, like History.checkout picks it.
    private var localBranch: String? {
        refs.first { !$0.isTag && !$0.name.hasPrefix("origin/") }?.name
    }

    /// How far a local branch here is from its upstream, as "↑2 ↓1". Nil when they match.
    private var drift: (branch: String, upstream: History.Upstream, counts: String)? {
        for ref in refs where !ref.isTag {
            guard let upstream = upstreams[ref.name], upstream.ahead + upstream.behind > 0 else { continue }
            let counts = [upstream.ahead > 0 ? "↑\(upstream.ahead)" : nil, upstream.behind > 0 ? "↓\(upstream.behind)" : nil]
            return (ref.name, upstream, counts.compactMap { $0 }.joined(separator: " "))
        }
        return nil
    }

    private func driftTip(_ branch: String, _ upstream: History.Upstream) -> String {
        let parts = [upstream.ahead > 0 ? "\(upstream.ahead) to push" : nil, upstream.behind > 0 ? "\(upstream.behind) to pull" : nil]
        return "\(branch) vs \(upstream.name): " + parts.compactMap { $0 }.joined(separator: ", ")
    }

    private var isHead: Bool { row.commit.refs.contains { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") } }

    /// The checked out branch first, then local branches, tags and remote ones. HEAD alone and origin/HEAD say nothing new.
    struct Ref {
        let name: String
        let isHead: Bool
        let isTag: Bool
        /// Set when the remote branch of the same name points here too, so both read as one badge.
        var remote: String?

        var names: [String] { [name] + (remote.map { ["\($0)/\(name)"] } ?? []) }
    }

    private var refs: [Ref] {
        var named: [(ref: Ref, rank: Int)] = row.commit.refs.compactMap { ref in
            if ref == "HEAD" || ref.hasSuffix("/HEAD") { return nil }
            if ref.hasPrefix("HEAD -> ") { return (Ref(name: String(ref.dropFirst("HEAD -> ".count)), isHead: true, isTag: false), 0) }
            if ref.hasPrefix("tag: ") { return (Ref(name: String(ref.dropFirst("tag: ".count)), isHead: false, isTag: true), 2) }
            return (Ref(name: ref, isHead: false, isTag: false), ref.hasPrefix("origin/") ? 3 : 1)
        }
        // main and origin/main on the same commit is one branch in sync with its remote, not two branches.
        for index in named.indices where named[index].rank < 2 {
            if let twin = named.firstIndex(where: { $0.rank == 3 && $0.ref.name == "origin/" + named[index].ref.name }) {
                named[index].ref.remote = "origin"
                named[twin].rank = -1
            }
        }
        return named.enumerated().filter { $0.element.rank >= 0 }
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element.ref)
    }

    /// Says "Copied" for a moment, since a copy otherwise leaves no trace.
    private func copyHash() {
        copy(row.commit.hash)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static let age: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// The selected commit under the history: its title, who and when, and the files it changed by folder.
/// Details, or any file, opens the full diff in the review panel.
private struct CommitPane: View {
    static let height: CGFloat = 250

    let commit: History.Commit
    /// Nil while git is still reading them.
    let files: [Diff.File]?
    let palette: Palette
    /// Opens the commit in the review panel, at a file when one was clicked.
    let review: (String?) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title sits in the bar, so the files get the room a second line would take.
            HStack(spacing: 6) {
                Text(commit.subject)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .hoverTip(commit.subject)
                Spacer(minLength: 6)
                IconButton(symbol: "arrow.up.right.square", help: "Open in review", palette: palette) { review(nil) }
                CloseButton(help: "Close", palette: palette, action: close)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 30)
            .background(palette.background)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(commit.author) · \(Self.date.string(from: commit.date)) · \(commit.shortHash)")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                        .padding(.bottom, 8)
                    if let files {
                        if files.isEmpty {
                            Text("No file changes.").font(.system(size: 12)).foregroundStyle(palette.muted)
                        }
                        ForEach(folders(files), id: \.folder) { group in
                            if !group.folder.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder").font(.system(size: 10.5))
                                    Text(group.folder.replacingOccurrences(of: "/", with: " / ")).font(.system(size: 11.5)).lineLimit(1)
                                }
                                .foregroundStyle(palette.muted)
                                .frame(height: 22)
                            }
                            ForEach(group.files, id: \.path) { file in
                                ChangedFile(file: file, palette: palette) { review(file.path) }
                                    .padding(.leading, group.folder.isEmpty ? 0 : 16)
                            }
                        }
                    } else {
                        Text("Loading…").font(.system(size: 12)).foregroundStyle(palette.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: Self.height)
    }

    /// Files grouped under their folder, folders in the order git lists them.
    private func folders(_ files: [Diff.File]) -> [(folder: String, files: [Diff.File])] {
        var groups: [(folder: String, files: [Diff.File])] = []
        for file in files {
            let folder = (file.path as NSString).deletingLastPathComponent
            if let index = groups.firstIndex(where: { $0.folder == folder }) {
                groups[index].files.append(file)
            } else {
                groups.append((folder, [file]))
            }
        }
        return groups
    }

    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct ChangedFile: View {
    let file: Diff.File
    let palette: Palette
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc").font(.system(size: 10.5)).foregroundStyle(palette.muted)
            Text((file.path as NSString).lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(file.status == .added ? palette.added : file.status == .deleted ? palette.muted : palette.text)
                .strikethrough(file.status == .deleted)
                .lineLimit(1)
                .truncationMode(.middle)
            if let note {
                Text(note).font(.system(size: 10.5)).foregroundStyle(palette.muted).lineLimit(1)
            }
            if !file.isBinary {
                Counts(added: file.added, removed: file.removed, palette: palette)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onClickableHover { hovering = $0 }
        .onTapGesture(perform: open)
        .hoverTip("\(file.path)\nOpen the changes in the review panel")
    }

    private var note: String? {
        if file.isBinary { return "binary" }
        switch file.status {
        case .added: return "new"
        case .deleted: return "deleted"
        case .renamed: return file.oldPath.map { "from \(($0 as NSString).lastPathComponent)" }
        case .modified: return nil
        }
    }
}

/// Branch names like ECE-1737-homepage-ajout-du-bloc… would make menus as wide as the screen. The dialogs still show them whole.
private func menuName(_ branch: String) -> String {
    branch.count > 20 ? branch.prefix(20) + "…" : branch
}

/// Shows git's own message, which says why and often what to do next, like resolving a conflict.
private func gitError(_ title: String) -> (String) -> Void {
    { message in
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        show(alert) { _ in }
    }
}

private func confirm(_ title: String, _ info: String, button: String, destructive: Bool = false, _ action: @escaping () -> Void) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = info
    let ok = alert.addButton(withTitle: button)
    ok.hasDestructiveAction = destructive
    alert.addButton(withTitle: "Cancel")
    show(alert) { if $0 == .alertFirstButtonReturn { action() } }
}

private func askBranchName(from start: String, suggested: String, _ action: @escaping (String) -> Void) {
    let alert = NSAlert()
    alert.messageText = "New branch from \(start)"
    alert.informativeText = "The new branch is checked out right away."
    let field = NSTextField(string: suggested)
    field.placeholderString = "Branch name"
    field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    show(alert) { response in
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if response == .alertFirstButtonReturn, !name.isEmpty { action(name) }
    }
}

private func show(_ alert: NSAlert, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
    if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
}
