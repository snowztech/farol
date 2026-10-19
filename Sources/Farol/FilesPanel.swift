import FarolCore
import SwiftUI

/// The folders you opened in the files panel and what they contain, kept up to date with the disk.
/// Folders are only read when opened, and nothing is watched while the panel is closed.
final class FileTree: ObservableObject {
    struct Row: Identifiable {
        let entry: Files.Entry
        let depth: Int
        let expanded: Bool
        let dimmed: Bool
        var id: String { entry.path }
    }

    @Published private(set) var root: String?
    @Published private(set) var rows: [Row] = []
    /// The file last opened from the panel, highlighted until another session is shown.
    @Published var selected: String?

    /// Open folders per root, so going back to a session finds its tree as you left it.
    private var expanded: [String: Set<String>] = [:]
    private var listings: [String: [Files.Entry]] = [:]
    private var ignored: Set<String> = []
    private var watcher: FolderWatcher?

    /// Shows another folder, or stops watching when `root` is nil.
    func show(_ root: String?) {
        let root = root.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        guard root != self.root || (root != nil && watcher == nil) else { return }
        watcher = nil
        self.root = root
        selected = nil
        listings = [:]
        ignored = []
        rows = []
        guard let root else { return }
        watcher = FolderWatcher(root) { [weak self] in self?.changed($0) }
        reload()
    }

    func toggle(_ folder: String) {
        guard let root else { return }
        if expanded[root, default: []].remove(folder) == nil { expanded[root, default: []].insert(folder) }
        rebuild()
    }

    /// Lists the root and every open folder again, and asks git what it ignores, off the main thread.
    private func reload(_ changed: [String]? = nil) {
        guard let root else { return }
        let folders = [root] + expanded[root, default: []].sorted()
        let stale = changed.map { Set($0) } ?? Set(folders)
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = Dictionary(uniqueKeysWithValues: folders.filter(stale.contains).map { ($0, Files.list($0)) })
            let ignored = Files.ignored(in: root)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == root else { return }
                self.listings.merge(fresh) { $1 }
                self.ignored = ignored
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        guard let root else { return }
        let open = expanded[root, default: []]
        let missing = open.filter { listings[$0] == nil }
        if !missing.isEmpty { return reload(Array(missing)) }
        var rows: [Row] = []
        func add(_ folder: String, depth: Int, dimmed: Bool) {
            for entry in listings[folder] ?? [] {
                let isOpen = entry.isDirectory && open.contains(entry.path)
                let dim = dimmed || entry.isHidden || ignored.contains(entry.path)
                rows.append(Row(entry: entry, depth: depth, expanded: isOpen, dimmed: dim))
                if isOpen { add(entry.path, depth: depth + 1, dimmed: dim) }
            }
        }
        add(root, depth: 0, dimmed: false)
        self.rows = rows
    }

    /// Git touches .git at every shell prompt, so only a .gitignore edit asks git again.
    private func changed(_ paths: [String]) {
        let outsideGit = paths.filter { !$0.contains("/.git/") }
        let folders = Set(outsideGit.map { ($0 as NSString).deletingLastPathComponent })
        let shown = folders.filter { listings[$0] != nil }
        if !shown.isEmpty || outsideGit.contains(where: { $0.hasSuffix("/.gitignore") }) { reload(Array(shown)) }
    }
}

/// The tree of the session's folder, or Find in Files in its place.
struct FilesPanel: View {
    static let defaultWidth: CGFloat = 240

    @ObservedObject var tree: FileTree
    @ObservedObject var state: WindowState
    @ObservedObject var search: FindInFilesModel
    /// A line of nil opens the file at its top.
    let open: (String, Int?) -> Void
    /// A search result, which also marks every match in the file.
    let openMatch: (String, Int) -> Void
    let resize: (CGFloat) -> Void
    /// The magnifier: Find in Files in place of the tree.
    let startSearch: () -> Void
    let close: () -> Void

    @State private var dragStart: CGFloat?

    var body: some View {
        let p = state.palette
        VStack(alignment: .leading, spacing: 0) {
            header(p)
            if state.filesSearching {
                FindInFiles(model: search, state: state, open: openMatch)
            } else {
                tree(p)
            }
        }
        // Fixed width, so closing the panel clips it instead of reflowing every row.
        .frame(width: state.filesWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(p.surface)
        .overlay(alignment: .trailing) { edge(p) }
    }

    /// The line between the panel and the terminal, wide enough to grab and drag.
    private func edge(_ p: Palette) -> some View {
        Rectangle().fill(p.boxed ? .clear : p.line).frame(width: 1)
            .frame(width: 7, alignment: .trailing)
            .contentShape(Rectangle())
            .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? state.filesWidth
                    dragStart = start
                    resize(start + drag.translation.width)
                }
                .onEnded { _ in dragStart = nil })
    }

    private func header(_ p: Palette) -> some View {
        HStack(spacing: 4) {
            IconButton(symbol: "chevron.left", help: "Hide files (⇧⌘E)", palette: p, action: close)
            Text(tree.root.map { ($0 as NSString).lastPathComponent } ?? (state.remote ? "Not available over ssh" : ""))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(p.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            // Like tabs: the lit one is what the panel shows, and the other switches to it.
            IconButton(symbol: "folder", help: "Files (esc)", active: !state.filesSearching, palette: p) {
                state.filesSearching = false
            }
            IconButton(symbol: "magnifyingglass", help: "Find in Files (⇧⌘F)", active: state.filesSearching, palette: p, action: startSearch)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func tree(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tree.rows) { row in
                        FileRow(row: row, selected: row.id == tree.selected, palette: p) {
                            if row.entry.isDirectory {
                                tree.toggle(row.entry.path)
                            } else {
                                tree.selected = row.entry.path
                                open(row.entry.path, nil)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }
}

private struct FileRow: View {
    let row: FileTree.Row
    let selected: Bool
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .bold))
                .rotationEffect(.degrees(row.expanded ? 90 : 0))
                .frame(width: 10)
                .opacity(row.entry.isDirectory ? 1 : 0)
            Image(systemName: row.entry.isDirectory ? "folder" : "doc")
                .font(.system(size: 11))
                .frame(width: 14)
            Text(row.entry.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(row.dimmed ? palette.muted : palette.text)
        .padding(.leading, CGFloat(row.depth) * 14 + 4)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? palette.raised : hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onClickableHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}
