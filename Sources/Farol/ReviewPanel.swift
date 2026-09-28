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
    /// Branches to compare with, the base one first.
    @Published private(set) var branches: [String] = []
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
            let local = Diff.branches(in: root)
            let branches = (base.map { [$0] } ?? []) + local.filter { base != $0 && base != "origin/\($0)" }
            let scope = Diff.defaultScope(in: root)
            let ignored = Files.ignored(in: root).map { $0 + "/" }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root else { return }
                self.branches = branches
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
    /// Opens a file in the file pane, at a line.
    let open: (String, Int) -> Void
    let close: () -> Void
    let resize: (CGFloat) -> Void

    @State private var dragStart: CGFloat?

    var body: some View {
        let p = state.palette
        VStack(alignment: .leading, spacing: 0) {
            header(p)
            ScopeMenu(review: review, palette: p)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
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
            FileHeader(file: file, collapsed: collapsed, palette: p,
                       toggle: { review.toggle(file.path) },
                       open: { review.root.map { open(($0 as NSString).appendingPathComponent(file.path), file.firstChange) } })
        case .gap(_, _, let lines):
            Text("\(lines) unmodified \(lines == 1 ? "line" : "lines")")
                .font(.system(size: 11))
                .foregroundStyle(p.muted)
                .padding(.leading, 58)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .background(p.surface)
                .padding(.horizontal, 8)
        case .line(_, _, let line):
            DiffLine(line: line, palette: p).padding(.horizontal, 8)
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
        Rectangle().fill(p.line).frame(width: 1)
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
        .onHover { hovering = $0 }
        .help("Choose what to compare with")
    }

    private var title: String {
        switch review.scope {
        case .uncommitted: "Uncommitted changes"
        case .branch(let base): "Changes since \(Self.name(base))"
        }
    }

    private func showMenu() {
        let menu = NSMenu()
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
private final class ActionMenuItem: NSMenuItem {
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
            Counts(added: file.added, removed: file.removed, palette: palette)
                .font(.system(size: 11))
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
