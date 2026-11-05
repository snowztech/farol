import AppKit
import FarolCore
import SwiftUI

/// The file pane: a tab per open file over the one in front. Each file keeps its own view, so its scroll, undo and unsaved edits stay.
/// A file opened by clicking through, from search or review, takes the preview tab, which the next one replaces.
/// So tabs don't pile up. Editing it or double-clicking its tab keeps it.
final class FileTabs: NSView {
    private(set) var files: [FileView] = []
    private(set) var current: FileView?
    private weak var preview: FileView?
    /// Wires a new file into the panes, as the pane container does for every view it holds.
    private let adopt: (FileView) -> Void
    /// The file in front changed, or a tab opened or closed.
    var onChange: (() -> Void)?
    /// The last tab closed, so the pane itself goes.
    var onEmpty: (() -> Void)?

    private let model = FileTabsModel()
    private let bar: NSHostingView<FileTabBar>
    private static let barHeight: CGFloat = 32

    init(palette: Palette?, adopt: @escaping (FileView) -> Void) {
        self.adopt = adopt
        bar = NSHostingView(rootView: FileTabBar(model: model))
        super.init(frame: .zero)
        model.palette = palette
        model.select = { [weak self] id in
            guard let self, let file = file(id) else { return }
            select(file)
            // A click on a tab is a click into the pane, so typing goes to that file.
            window?.makeFirstResponder(file.textView)
        }
        model.close = { [weak self] id in self?.file(id).map { self?.close($0) } }
        model.keep = { [weak self] id in self?.file(id).map { self?.keep($0) } }
        model.closeOthers = { [weak self] id in self?.file(id).map { self?.close(except: $0) } }
        model.togglePreview = { [weak self] in self?.current?.togglePreview() }
        model.closeAll = { [weak self] in self?.close(except: nil) }
        addSubview(bar)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    var palette: Palette? {
        get { model.palette }
        set { model.palette = newValue }
    }

    /// Brings `path` to the front: its tab if it has one, else the preview tab, else a new one beside the current.
    /// `keep` opens it as a tab of its own, as a click in the files panel does.
    func open(_ path: String, line: Int?, keep: Bool) {
        if let open = files.first(where: { $0.path == path }) {
            if keep { self.keep(open) }
            select(open)
            if let line { open.reveal(line: line) }
            return
        }
        if let preview, !keep, !preview.isDirty {
            preview.show(path)
            if let line { preview.reveal(line: line) }
            return select(preview)
        }
        let file = FileView(path: path)
        file.onStateChange = { [weak self, weak file] in
            // An edit keeps the file, so the next click through doesn't replace work in progress.
            if let file, file.isDirty, self?.preview === file { self?.preview = nil }
            self?.refresh()
        }
        adopt(file)
        files.insert(file, at: current.flatMap { files.firstIndex(of: $0) }.map { $0 + 1 } ?? files.count)
        addSubview(file)
        if !keep { preview = file }
        if let line { file.reveal(line: line) }
        select(file)
    }

    /// Restores saved tabs, the first `active` in front, every one kept.
    func restore(_ paths: [String], active: Int) {
        for path in paths where FileManager.default.fileExists(atPath: path) { open(path, line: nil, keep: true) }
        if files.indices.contains(active) { select(files[active]) }
    }

    func select(_ file: FileView) {
        current = file
        for other in files { other.isHidden = other !== file }
        needsLayout = true
        refresh()
        onChange?()
    }

    /// ⌃Tab and ⌃⇧Tab: the next or previous tab, round from the last to the first.
    func step(_ by: Int) {
        guard let current, let index = files.firstIndex(of: current) else { return }
        select(files[(index + by + files.count) % files.count])
    }

    /// Asks first when it has unsaved edits. The tab to its right comes forward, as in Safari.
    func close(_ file: FileView) {
        file.confirmClose { [weak self] in self?.remove(file) }
    }

    /// Every tab but `kept`, one at a time, each asking about its unsaved edits.
    func close(except kept: FileView?) {
        guard let next = files.last(where: { $0 !== kept }) else { return }
        next.confirmClose { [weak self] in
            self?.remove(next)
            self?.close(except: kept)
        }
    }

    /// The first file with unsaved edits, brought to the front so you see what you are asked about.
    func unsaved() -> FileView? {
        guard let file = files.first(where: \.isDirty) else { return nil }
        select(file)
        return file
    }

    private func remove(_ file: FileView) {
        guard let index = files.firstIndex(of: file) else { return }
        files.remove(at: index)
        file.removeFromSuperview()
        guard !files.isEmpty else {
            current = nil
            return onEmpty?() ?? ()
        }
        if current === file { select(files[min(index, files.count - 1)]) } else { refresh(); onChange?() }
    }

    private func keep(_ file: FileView) {
        if preview === file { preview = nil }
        refresh()
    }

    private func file(_ id: ObjectIdentifier) -> FileView? {
        files.first { ObjectIdentifier($0) == id }
    }

    /// The bar follows the files: names, unsaved dots, which one is in front, and its actions.
    private func refresh() {
        let names = files.map { ($0.path as NSString).lastPathComponent }
        model.tabs = files.map { file in
            let name = (file.path as NSString).lastPathComponent
            // Two index.ts read the same, so each says which folder it is in.
            let folder = names.filter { $0 == name }.count > 1
                ? ((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent : nil
            return FileTabsModel.Tab(id: ObjectIdentifier(file), path: file.path, name: name, folder: folder,
                                     dirty: file.isDirty, preview: file === preview)
        }
        model.active = current.map(ObjectIdentifier.init)
        model.canPreview = current?.canPreview == true
        model.previewing = current?.isPreviewing == true
    }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        current?.frame = NSRect(x: 0, y: Self.barHeight, width: bounds.width, height: max(0, bounds.height - Self.barHeight))
    }

    /// A click on the bar picks the pane, as a click on a file's header did.
    override func mouseDown(with event: NSEvent) {
        if let current { window?.makeFirstResponder(current.textView) }
    }
}

final class FileTabsModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier
        let path: String
        let name: String
        let folder: String?
        let dirty: Bool
        let preview: Bool
    }

    @Published var tabs: [Tab] = []
    @Published var active: ObjectIdentifier?
    @Published var palette: Palette?
    @Published var canPreview = false
    @Published var previewing = false
    var select: (ObjectIdentifier) -> Void = { _ in }
    var close: (ObjectIdentifier) -> Void = { _ in }
    var keep: (ObjectIdentifier) -> Void = { _ in }
    var closeOthers: (ObjectIdentifier) -> Void = { _ in }
    var togglePreview: () -> Void = {}
    var closeAll: () -> Void = {}
}

struct FileTabBar: View {
    @ObservedObject var model: FileTabsModel

    var body: some View {
        if let p = model.palette {
            HStack(spacing: 4) {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(model.tabs) { tab in
                                FileTabItem(tab: tab, active: tab.id == model.active, palette: p, model: model).id(tab.id)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    // The tab in front stays in full view, also when a tab opens past the edge or the bar narrows.
                    // After layout, since a tab added in the same change has no width yet to scroll to.
                    .onChange(of: model.active) { _, _ in reveal(scroll) }
                    .onChange(of: model.tabs) { _, _ in reveal(scroll) }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in reveal(scroll) }
                }
                HStack(spacing: 2) {
                    if model.canPreview {
                        IconButton(symbol: model.previewing ? "chevron.left.forwardslash.chevron.right" : "eye",
                                   help: model.previewing ? "Show the source" : "Preview", palette: p, action: model.togglePreview)
                    }
                    IconButton(symbol: "xmark", help: "Close all files", palette: p, action: model.closeAll)
                }
                .padding(.trailing, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 1) }
        }
    }

    private func reveal(_ scroll: ScrollViewProxy) {
        guard let active = model.active else { return }
        DispatchQueue.main.async {
            withAnimation(Motion.enabled ? .easeOut(duration: 0.15) : nil) { scroll.scrollTo(active) }
        }
    }
}

/// A tab: the file's icon and name, in italics while it is the preview. Its close button shows on hover and on the one in front.
/// An unsaved file shows a dot there instead, as in other editors.
private struct FileTabItem: View {
    let tab: FileTabsModel.Tab
    let active: Bool
    let palette: Palette
    let model: FileTabsModel
    @State private var hovering = false

    var body: some View {
        let p = palette
        HStack(spacing: 6) {
            // As wide as the widest mark, Go's, so none spills over the name.
            FileIcon(path: tab.path).font(.system(size: 11)).foregroundStyle(p.muted).frame(width: 20)
            Text(tab.name)
                .font(.system(size: 12))
                .italic(tab.preview)
                .foregroundStyle(active ? p.text : p.muted)
                .lineLimit(1)
            if let folder = tab.folder {
                Text(folder).font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1)
            }
            trailing(p)
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? p.selection : hovering ? p.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.select(tab.id) }
        // Alongside the single tap, so selecting never waits to see whether a second tap comes.
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.keep(tab.id) })
        .onClickableHover { hovering = $0 }
        .help((tab.path as NSString).abbreviatingWithTildeInPath)
        .contextMenu {
            Button("Close") { model.close(tab.id) }
            Button("Close Others") { model.closeOthers(tab.id) }
            if tab.preview { Button("Keep Open") { model.keep(tab.id) } }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.path, forType: .string)
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tab.path)]) }
        }
    }

    @ViewBuilder
    private func trailing(_ p: Palette) -> some View {
        ZStack {
            if hovering || (active && !tab.dirty) {
                Button { model.close(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(p.muted)
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(QuietPress())
                .help("Close (⌘W)")
            } else if tab.dirty {
                Circle().fill(p.muted).frame(width: Lamp.size, height: Lamp.size).help("Unsaved changes (⌘S to save)")
            }
        }
        .frame(width: 16, height: 16)
    }
}
