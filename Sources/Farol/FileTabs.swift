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
    /// Runs a command in a new terminal pane, as installing a language server does, so you see it happen.
    var runCommand: ((String) -> Void)?
    /// Go to Line is about to move the cursor to this line of the file in front, so the place it leaves can be gone back to.
    var willJump: ((String, Int) -> Void)?

    private let model = FileTabsModel()
    private let bar: NSHostingView<FileTabBar>
    private static let barHeight: CGFloat = 32
    /// The bar under the code: its language servers on the left, the cursor and the language on the right.
    /// Always there with a file open, so the code never shifts.
    private let status: NSHostingView<FileStatusBar>
    private static let statusHeight: CGFloat = 24

    init(palette: Palette?, adopt: @escaping (FileView) -> Void) {
        self.adopt = adopt
        bar = NSHostingView(rootView: FileTabBar(model: model))
        status = NSHostingView(rootView: FileStatusBar(model: model))
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
        model.openServerMenu = { [weak self] in self?.openServerMenu() }
        model.askLine = { [weak self] in self?.askLine() }
        addSubview(bar)
        addSubview(status)
        NotificationCenter.default.addObserver(self, selector: #selector(serversChanged), name: LanguageServers.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(serversTurnedOn), name: LanguageServers.didTurnOn, object: nil)
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
        file.onCursorChange = { [weak self, weak file] in
            guard let self, let file, file === current else { return }
            refreshFacts()
            // Back in the file after installing its server in a pane: notice it. Throttled, and only while it's missing.
            if model.server?.state == .missing { refreshServer() }
        }
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
        // Only the tab in front, so tabs restored at launch don't each start a server.
        file.warmLanguageServer()
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
        file.closed()
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
        refreshFacts()
        refreshServer()
    }

    // MARK: Status bar

    /// Where the cursor is, for the bar under the code.
    private func refreshFacts() {
        guard let current else { return model.facts = nil }
        let cursor = current.cursor
        let facts = FileTabsModel.Facts(
            cursor: "\(cursor.line):\(cursor.column)" + (cursor.selected > 0 ? " (\(cursor.selected) selected)" : ""),
            line: cursor.line, lines: current.lineCount)
        if model.facts != facts { model.facts = facts }
    }

    // MARK: Language server

    @objc private func serversChanged() { refreshServer() }
    @objc private func serversTurnedOn() { current?.warmLanguageServer() }

    /// The bolt in the status bar follows the file in front's server: its dot filled while it runs, empty when stopped.
    /// A spinner while it loads the project. Gray, since a colored dot in Farol is an agent's.
    private func refreshServer() {
        let servers = LanguageServers.shared
        guard let path = current?.path, let server = LSP.server(for: path) else {
            if model.server != nil { model.server = nil }
            return
        }
        let installed = servers.isInstalled(server)
        if installed == nil { servers.locateAll { [weak self] in self?.refreshServer() } }
        // Installed from the bar a moment ago, so look again rather than keep saying it's missing.
        if installed == false { servers.recheck(server) { [weak self] in self?.refreshServer() } }
        let running = servers.existing(for: path)
        let state: FileTabsModel.Server.State = if !servers.isEnabled(server) {
            .off
        } else {
            switch running?.state {
            case .starting: .loading
            case .running: .running
            case .failed: .failed
            case .stopped, nil: installed == false ? .missing : .stopped
            }
        }
        let status = FileTabsModel.Server(name: server.name, language: LSP.languageName(for: path) ?? server.language,
                                          state: state)
        if model.server != status { model.server = status }
    }

    /// ⌘L or a click on the line and column: a field to type where to go, at the top of the file, where Zed and VS Code put it.
    func askLine() {
        guard let current, let window, let facts = model.facts, let palette = model.palette else { return }
        let file = window.convertToScreen(current.convert(current.bounds, to: nil))
        FloatingPanel.show(palette: palette, over: window, place: { size, _ in
            NSPoint(x: file.midX - size.width / 2, y: file.maxY - size.height - 10)
        }) { dismiss in
            GoToLine(facts: facts, palette: palette) { [weak self] text in
                dismiss()
                self?.goToLine(text)
            }
        }
    }

    /// "12" goes to line 12, "12:5" to its fifth column. Anything else leaves the cursor where it was.
    private func goToLine(_ text: String) {
        let parts = text.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let current, let line = parts.first ?? nil else { return }
        willJump?(current.path, line)
        current.goTo(line: line, column: parts.count > 1 ? (parts[1] ?? 1) : 1)
    }

    /// The same menu as a right-click in the code, opened above the server's name.
    private func openServerMenu() {
        guard let path = current?.path else { return }
        let menu = LanguageServerMenu.make(for: path, openLog: { [weak self] in self?.open($0, line: $1, keep: true) },
                                           install: { [weak self] in self?.runCommand?($0) })
        menu.popUp(positioning: nil, at: NSPoint(x: status.frame.maxX - 160, y: status.frame.minY), in: self)
    }

    override func layout() {
        super.layout()
        let foot = Self.statusHeight
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        current?.frame = NSRect(x: 0, y: Self.barHeight, width: bounds.width, height: max(0, bounds.height - Self.barHeight - foot))
        status.frame = NSRect(x: 0, y: bounds.height - foot, width: bounds.width, height: foot)
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
    /// The file in front's language server, beside its language in the status bar. Nil with language servers off.
    @Published var server: Server?
    @Published var facts: Facts?

    struct Facts: Equatable {
        let cursor: String
        let line: Int
        let lines: Int
    }

    struct Server: Equatable {
        let name: String
        /// The file's language, which the bar shows, since a server's name like sourcekit-lsp means little to most people.
        let language: String
        let state: State

        enum State {
            /// Turned off for this language, so the name sits dim, and a click offers to turn it on.
            case off
            case loading, running, stopped, failed, missing

            /// The bolt's tip, like Zed's: what the servers are doing, in a few words.
            func tip(_ name: String) -> String {
                switch self {
                case .off: "Language server off. Click to enable \(name)"
                case .loading: "Language servers · \(name) is loading the project"
                case .running: "Language servers · \(name) is running"
                case .stopped: "Language servers · \(name) starts when you ⌘-click"
                case .failed: "Language servers · \(name) stopped with an error"
                case .missing: "\(name) isn't installed. Click to install it"
                }
            }
        }
    }

    var select: (ObjectIdentifier) -> Void = { _ in }
    var close: (ObjectIdentifier) -> Void = { _ in }
    var keep: (ObjectIdentifier) -> Void = { _ in }
    var closeOthers: (ObjectIdentifier) -> Void = { _ in }
    var togglePreview: () -> Void = {}
    var closeAll: () -> Void = {}
    var openServerMenu: () -> Void = {}
    var askLine: () -> Void = {}
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
            // Against the name, so every icon sits as far from it, whatever its width. Go's wide mark reaches into the padding instead.
            FileIcon(path: tab.path, alignment: .trailing).font(.system(size: 11)).foregroundStyle(p.muted)
                .frame(width: 20, alignment: .trailing)
            // The one in front in medium weight and the others a step dimmer, so the tab you're in reads at a glance.
            Text(tab.name)
                .font(.system(size: 12, weight: active ? .medium : .regular))
                .italic(tab.preview)
                .foregroundStyle(active ? p.text : p.text.opacity(0.7))
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

/// The bar under the code, in small muted type, as Zed has it: the cursor's line and column on the left, which opens Go to Line.
/// On the right the language server and its state, which opens its menu, or the file's language when there is none.
struct FileStatusBar: View {
    @ObservedObject var model: FileTabsModel

    var body: some View {
        if let p = model.palette, let facts = model.facts {
            HStack(spacing: 14) {
                StatusButton(palette: p, tip: "Go to Line (⌘L)", action: model.askLine) { _ in
                    Text(facts.cursor).monospacedDigit()
                }
                Spacer(minLength: 8)
                if let server = model.server {
                    // The language and a dot in every state, so the corner stays quiet. A click opens the menu, which says what to do.
                    StatusButton(palette: p, tip: server.state.tip(server.name), action: model.openServerMenu) { _ in
                        label(server)
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(p.muted)
            .lineLimit(1)
            .padding(.horizontal, 6)
            // A point lower, for the divider along the top, so the text looks centered rather than measures it.
            .padding(.top, 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(p.background)
            .overlay(alignment: .top) { Rectangle().fill(p.line).frame(height: 1) }
        }
    }

    /// The language and one gray dot, in the same place in every state, so only the dot changes.
    /// Gray, since a colored dot in Farol is an agent's.
    @ViewBuilder private func label(_ server: FileTabsModel.Server) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            // Lowercase, like the file names and the line and column around it.
            Text(server.language.lowercased())
            if server.state == .failed {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 9))
            } else {
                ServerDot(state: server.state, on: model.palette?.text ?? .primary)
            }
        }
        .opacity(server.state == .off || server.state == .missing ? 0.7 : 1)
    }
}

/// One dot, centered on the lowercase language name: its middle half an x-height above the baseline, from the font itself.
/// Bright, in the text's color, while the server runs, and faint otherwise. Still, so the corner stays quiet.
private struct ServerDot: View {
    let state: FileTabsModel.Server.State
    let on: Color
    /// The status bar's type, whose lowercase letters the dot centers on.
    private static let xHeight = NSFont.systemFont(ofSize: 11).xHeight

    var body: some View {
        Circle()
            .fill(state == .running ? on : Color.secondary)
            .frame(width: 5, height: 5)
            .opacity(state == .running ? 1 : 0.5)
            // Lined up on the text's baseline, the circle's center lands half an x-height above it.
            .alignmentGuide(.firstTextBaseline) { $0.height / 2 + Self.xHeight / 2 }
    }
}

/// Something in the status bar that does something: brighter under the mouse, with the hand and a tip.
private struct StatusButton<Label: View>: View {
    let palette: Palette
    /// Nil when the label already says what a click does.
    let tip: String?
    let action: () -> Void
    /// Gets whether the mouse is over it, for a label that says what a click does once you point at it.
    @ViewBuilder let label: (Bool) -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label(hovering)
                .foregroundStyle(hovering ? palette.text : palette.muted)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? palette.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietPress())
        .onClickableHover { hovering = $0 }
        // The pointer style alone didn't take in this bar, under the file's text view, so the hand is also set while over it.
        .onContinuousHover { phase in if case .active = phase { NSCursor.pointingHand.set() } }
        .hoverTip(tip ?? "")
    }
}

/// Go to Line, shaped like the ⌘P switcher: a field with its mark and shortcut, then where you are and what to type.
private struct GoToLine: View {
    let facts: FileTabsModel.Facts
    let palette: Palette
    let go: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let p = palette
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "number").foregroundStyle(p.muted)
                TextField("Go to line", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { go(text) }
                Text("⌘L").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
            }
            .padding(12)
            Rectangle().fill(p.line).frame(height: 1)
            Text("Line \(facts.line) of \(facts.lines). Type a line, or line:column like 12:5.")
                .font(.system(size: 11))
                .foregroundStyle(p.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .frame(width: 320)
        .onAppear { focused = true }
    }
}
