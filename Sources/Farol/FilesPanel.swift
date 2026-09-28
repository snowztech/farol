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

struct FilesPanel: View {
    static let width: CGFloat = 240

    @ObservedObject var tree: FileTree
    @ObservedObject var state: WindowState
    let open: (String) -> Void

    var body: some View {
        let p = state.palette
        VStack(alignment: .leading, spacing: 0) {
            Text(tree.root.map { ($0 as NSString).lastPathComponent } ?? "")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(p.muted)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tree.rows) { row in
                        FileRow(row: row, selected: row.id == tree.selected, palette: p) {
                            if row.entry.isDirectory {
                                tree.toggle(row.entry.path)
                            } else {
                                tree.selected = row.entry.path
                                open(row.entry.path)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        // Fixed width, so closing the panel clips it instead of reflowing every row.
        .frame(width: Self.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(p.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(p.line).frame(width: 1) }
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
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? palette.raised : hovering ? palette.raised.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onClickableHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help((row.entry.path as NSString).abbreviatingWithTildeInPath)
    }
}
