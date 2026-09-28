import AppKit
import FarolCore
import SwiftUI

/// The selected session's changes. The count in the title bar is always current. The full diff is only read while the panel is open.
final class ReviewModel: ObservableObject {
    enum Row: Identifiable {
        case header(Diff.File, collapsed: Bool)
        /// Unchanged lines git left out between two hunks.
        case gap(file: String, index: Int, lines: Int)
        case line(file: String, index: Int, Diff.Line)
        case note(file: String, String)

        var id: String {
            switch self {
            case .header(let file, _): file.path
            case .gap(let file, let index, _): "\(file)#gap\(index)"
            case .line(let file, let index, _): "\(file)#\(index)"
            case .note(let file, _): "\(file)#note"
            }
        }
    }

    @Published private(set) var root: String?
    @Published private(set) var branch: String?
    @Published private(set) var scope = Diff.Scope.uncommitted
    /// The branch "since" compares against. Nil when the repo has none, which hides the choice.
    @Published private(set) var base: String?
    @Published private(set) var stat = Diff.Stat()
    @Published private(set) var rows: [Row] = []
    @Published private(set) var error: String?
    @Published var isOpen = false { didSet { if isOpen != oldValue { refresh() } } }

    private var files: [Diff.File] = []
    private var collapsed: Set<String> = []
    /// Your choice per checkout, so switching sessions doesn't reset it.
    private var chosenScope: [String: Diff.Scope] = [:]
    private var ignored: [String] = []
    private var watcher: FolderWatcher?
    private var pending: DispatchWorkItem?

    /// Big diffs, like a lockfile, start folded so they don't bury everything else.
    private static let foldedAbove = 800

    /// Follows another checkout, or stops when `root` is nil, as outside a git repo.
    func follow(_ root: String?, branch: String?) {
        let branchChanged = branch != self.branch
        self.branch = branch
        guard root != self.root || branchChanged else { return refresh() }
        let rootChanged = root != self.root
        self.root = root
        if rootChanged {
            watcher = nil
            files = []
            collapsed = []
            rows = []
            stat = Diff.Stat()
            ignored = []
        }
        guard let root else { return }
        if rootChanged { watcher = FolderWatcher(root) { [weak self] in self?.changed($0) } }
        DispatchQueue.global(qos: .userInitiated).async {
            let base = Diff.baseBranch(in: root)
            let scope = Diff.defaultScope(in: root)
            let ignored = Files.ignored(in: root).map { $0 + "/" }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root else { return }
                self.base = base
                self.ignored = ignored
                self.scope = self.chosenScope[root] ?? scope
                self.refresh()
            }
        }
    }

    func choose(_ scope: Diff.Scope) {
        guard let root, scope != self.scope else { return }
        chosenScope[root] = scope
        self.scope = scope
        refresh()
    }

    func toggle(_ path: String) {
        if collapsed.remove(path) == nil { collapsed.insert(path) }
        rebuild()
    }

    /// Reads the counts, and the whole diff when the panel is open, off the main thread.
    func refresh() {
        pending?.cancel()
        guard let root else { return }
        let scope = scope, withFiles = isOpen
        DispatchQueue.global(qos: .userInitiated).async {
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
                    self.rebuild()
                }
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
            var index = 0
            var next = 1
            for (h, hunk) in file.hunks.enumerated() {
                let skipped = hunk.newStart - next
                if skipped > 0 { rows.append(.gap(file: file.path, index: h, lines: skipped)) }
                for line in hunk.lines {
                    rows.append(.line(file: file.path, index: index, line))
                    index += 1
                }
                next = hunk.newStart + hunk.lines.filter { $0.kind != .removed }.count
            }
        }
        self.rows = rows
    }
}

struct ReviewPanel: View {
    static let defaultWidth: CGFloat = 560

    @ObservedObject var review: ReviewModel
    @ObservedObject var state: WindowState
    let open: (String) -> Void
    let close: () -> Void
    let resize: (CGFloat) -> Void

    @State private var dragStart: CGFloat?

    var body: some View {
        let p = state.palette
        VStack(alignment: .leading, spacing: 0) {
            header(p)
            if let base = review.base {
                Picker("", selection: Binding(get: { review.scope }, set: { review.choose($0) })) {
                    Text("Uncommitted").tag(Diff.Scope.uncommitted)
                    Text("Since \(base.replacingOccurrences(of: "origin/", with: ""))").tag(Diff.Scope.branch(base: base))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            Rectangle().fill(p.line).frame(height: 1)
            if let error = review.error {
                message(error, p)
            } else if review.rows.isEmpty {
                message(review.root == nil ? "Not a git repository." : "No changes.", p)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(review.rows) { row(for: $0, p) }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(p.background)
        .overlay(alignment: .leading) { edge(p) }
    }

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
            IconButton(symbol: "xmark", help: "Close review (⌥⌘R)", palette: p, action: close)
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
            FileHeader(file: file, collapsed: collapsed, palette: p,
                       toggle: { review.toggle(file.path) },
                       open: { review.root.map { open(($0 as NSString).appendingPathComponent(file.path)) } })
        case .gap(_, _, let lines):
            Text("\(lines) unmodified \(lines == 1 ? "line" : "lines")")
                .font(.system(size: 11))
                .foregroundStyle(p.muted)
                .padding(.leading, 58)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .background(p.surface)
        case .line(_, _, let line):
            DiffLine(line: line, palette: p)
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
        Rectangle().fill(p.line).frame(width: 1)
            .frame(width: 7)
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
        .monospacedDigit()
    }
}

private struct FileHeader: View {
    let file: Diff.File
    let collapsed: Bool
    let palette: Palette
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
            (Text(folder).foregroundColor(palette.muted) + Text(name).foregroundColor(palette.text))
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.head)
            if let status { Text(status).font(.system(size: 11)).foregroundStyle(palette.muted) }
            Counts(added: file.added, removed: file.removed, palette: palette).font(.system(size: 11.5))
            Spacer(minLength: 8)
            IconButton(symbol: "doc.on.doc", help: "Copy path", palette: palette) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            if file.status != .deleted {
                IconButton(symbol: "arrow.up.forward.square", help: "Open file", palette: palette, action: open)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(hovering ? palette.raised : palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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

private struct DiffLine: View {
    let line: Diff.Line
    let palette: Palette

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(tint.opacity(line.kind == .context ? 0 : 0.9)).frame(width: 3)
            Text(line.number.map(String.init) ?? "")
                .foregroundStyle(palette.muted)
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 11)
            // Tabs would line up differently from the file, so they show as four spaces.
            Text(line.text.replacingOccurrences(of: "\t", with: "    "))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(height: 20)
        .background(tint.opacity(line.kind == .context ? 0 : 0.14))
        .clipped()
    }

    private var tint: Color { line.kind == .removed ? palette.removed : palette.added }
}
