import FarolCore
import SwiftUI

/// UI state shared by the SwiftUI pieces of the window.
final class WindowState: ObservableObject {
    @Published var palette: Palette
    @Published var showingSettings = false
    /// The three column merge view replaces the terminal while git is stopped on conflicts.
    @Published var showingMerge = false
    /// The session list under the title is open, from a click or ⌘P.
    @Published var switchingSession = false
    /// Mirrors the sidebar and the files panel, so the top bar can match the columns below it.
    @Published var sidebarVisible = true
    @Published var filesVisible = false
    @Published var graphVisible = false
    /// Zero while the graph panel is closed.
    @Published var graphWidth: CGFloat = 0
    /// Zero while the review panel is closed.
    @Published var reviewWidth: CGFloat = 0
    let ghosttyConfigPreview: ThemeColors?
    @Published var style = UIStyle.saved {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: UIStyle.key) }
    }

    init(palette: Palette, ghosttyConfigPreview: ThemeColors?) {
        self.palette = palette
        self.ghosttyConfigPreview = ghosttyConfigPreview
    }
}

struct Commands {
    let newSession: () -> Void
    let newTask: () -> Void
    let closeSession: (Session) -> Void
    let toggleSidebar: () -> Void
    let toggleFiles: () -> Void
    let toggleGraph: () -> Void
    let toggleReview: () -> Void
    let toggleSettings: () -> Void
    let toggleMerge: () -> Void
    let openFile: (String) -> Void
    let titleBarDoubleClick: () -> Void
}

struct TopBar: View {
    @ObservedObject var state: WindowState
    @ObservedObject var store: SessionStore
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var review: ReviewModel
    @ObservedObject var merge: MergeModel
    let commands: Commands

    var body: some View {
        let p = state.palette
        ZStack {
            Group {
                if state.showingSettings {
                    Text("Settings")
                } else if let session = store.selected {
                    SessionMenu(session: session, store: store, state: state, openFile: commands.openFile)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(p.muted)
            .lineLimit(1)
            // Centered over the content, between the open panels, so it never sits on a panel's edge.
            // Boxed, the bar is one strip with no panel running up into it, so the title sits in the middle of the window.
            .padding(.horizontal, 120)
            .frame(maxWidth: .infinity)
            .padding(.leading, p.boxed ? 0 : leftPanels)
            .padding(.trailing, p.boxed ? 0 : reviewWidth + graphWidth)
            // On a window too narrow for all of this, only the title gives way. The buttons stay where they are.
            .frame(minWidth: 0)

            HStack(spacing: 2) {
                // Room for the traffic lights.
                Spacer().frame(width: 72)
                IconButton(symbol: "sidebar.left", help: "Sidebar (⌘B)", active: state.sidebarVisible,
                           palette: p, action: commands.toggleSidebar)
                IconButton(symbol: "folder", help: "Files (⇧⌘E)", active: state.filesVisible,
                           palette: p, action: commands.toggleFiles)
                newSessionButton(p)
                Spacer()
                if let session = store.selected {
                    GitButton(session: session, state: state, review: review, merge: merge,
                              graph: commands.toggleGraph, changes: commands.toggleReview, conflicts: commands.toggleMerge)
                }
                if let version = updates.available {
                    UpdateBadge(version: version, palette: p, action: updates.install)
                        .padding(.trailing, 6)
                }
                IconButton(symbol: "gearshape", help: "Settings (⌘,)", active: state.showingSettings,
                           palette: p, action: commands.toggleSettings)
            }
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { columns(p) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: commands.titleBarDoubleClick)
    }

    /// Width of the side panels open on the left, which the title stays clear of.
    private var leftPanels: CGFloat {
        (state.sidebarVisible ? SidebarView.width : 0) + (filesVisible ? FilesPanel.width : 0)
    }

    // The merge view covers every panel but the sidebar, so the bar is laid out as if they were closed.
    private var filesVisible: Bool { state.filesVisible && !state.showingMerge }
    private var reviewWidth: CGFloat { state.showingMerge ? 0 : state.reviewWidth }
    private var graphWidth: CGFloat { state.showingMerge ? 0 : state.graphWidth }

    /// Every panel runs up into the bar in its own color, like Mac apps with a sidebar, and the terminal's part matches the terminal.
    @ViewBuilder private func columns(_ p: Palette) -> some View {
        // Boxed, the panels are cards below the bar, and the bar is part of what is around them.
        if p.boxed {
            p.backdrop
        } else {
            touchingColumns(p)
        }
    }

    private func touchingColumns(_ p: Palette) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(p.surface).frame(width: state.sidebarVisible ? SidebarView.width - 1 : 0)
            Rectangle().fill(p.line).frame(width: state.sidebarVisible ? 1 : 0)
            Rectangle().fill(p.surface).frame(width: filesVisible ? FilesPanel.width - 1 : 0)
            Rectangle().fill(p.line).frame(width: filesVisible ? 1 : 0)
            Rectangle().fill(p.background)
            Rectangle().fill(p.line).frame(width: reviewWidth > 0 ? 1 : 0)
            Rectangle().fill(p.background).frame(width: max(reviewWidth - 1, 0))
            Rectangle().fill(p.line).frame(width: graphWidth > 0 ? 1 : 0)
            Rectangle().fill(p.surface).frame(width: max(graphWidth - 1, 0))
        }
    }

    private func newSessionButton(_ p: Palette) -> some View {
        IconButton(symbol: "plus", help: "New session (⌘T)", palette: p, action: commands.newSession)
    }

}

/// Only there when a newer release exists, so it never takes room otherwise.
private struct UpdateBadge: View {
    let version: String
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Update")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? palette.text : palette.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(palette.raised.opacity(hovering ? 1 : 0.6), in: Capsule())
                .overlay(Capsule().strokeBorder(palette.line))
        }
        .buttonStyle(QuietPress())
        .onClickableHover { hovering = $0 }
        .hoverTip("Farol \(version) is available. Download it.")
    }
}

/// "⛬ +821 −61": the graph icon opens the graph, the counts open the review.
/// Only in a git repo, or while a panel is open so it can still be closed. The counts, and the pill around both, only when there are changes.
/// While git is stopped on a merge or a rebase, "3 conflicts" comes first and opens the three column view.
private struct GitButton: View {
    @ObservedObject var session: Session
    @ObservedObject var state: WindowState
    @ObservedObject var review: ReviewModel
    @ObservedObject var merge: MergeModel
    let graph: () -> Void
    let changes: () -> Void
    let conflicts: () -> Void

    var body: some View {
        let p = state.palette
        let counts = !review.changes.isEmpty || review.isOpen
        let stopped = merge.operation != nil
        if !counts, !stopped, session.topLevel != nil || state.graphVisible {
            // Alone, the icon sits bare like the others in the title bar. A pill around it reads as switched on.
            IconButton(symbol: "point.3.filled.connected.trianglepath.dotted", help: "Git graph (⌥⌘G)", active: state.graphVisible,
                       palette: p, action: graph)
        } else if counts || stopped {
            // The gap between the halves is the divider, so a lit half ends cleanly against it.
            HStack(spacing: 1) {
                if stopped {
                    Half(active: state.showingMerge, help: "Resolve conflicts (⌥⌘M)", palette: p, action: conflicts) { color in
                        HStack(spacing: 6) {
                            Circle().fill(merge.hasConflicts ? p.waiting : p.done).frame(width: 6, height: 6)
                            Text(conflictLabel).foregroundStyle(color)
                        }
                    }
                }
                Half(active: state.graphVisible, help: "Git graph (⌥⌘G)", palette: p, action: graph) { color in
                    // The size of the gear next to it.
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(color)
                }
                if counts {
                    // Over a commit it isn't lit: a click there brings your changes back.
                    Half(active: review.isOpen && !review.showsCommit, help: "Review changes (⌥⌘R)", palette: p, action: changes) { _ in
                        Counts(added: review.changes.added, removed: review.changes.removed, palette: p)
                    }
                }
            }
            .font(.system(size: 11, weight: .medium))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(p.line))
            .padding(.trailing, 6)
        }
    }

    private var conflictLabel: String {
        let count = merge.conflicts.count
        return count == 0 ? "Ready to continue" : "\(count) \(count == 1 ? "conflict" : "conflicts")"
    }

    /// One clickable side of the pill, lit while hovered and brighter while its panel is open.
    private struct Half<Label: View>: View {
        let active: Bool
        let help: String
        let palette: Palette
        let action: () -> Void
        @ViewBuilder let label: (Color) -> Label

        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                label(active ? palette.accent : hovering ? palette.text : palette.muted)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(active ? palette.muted.opacity(0.3) : palette.raised.opacity(hovering ? 1 : 0.6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuietPress())
            .onClickableHover { hovering = $0 }
            .hoverTip(help)
        }
    }
}

/// The title opens a searchable list of every session, grouped like the sidebar, so you can switch with the sidebar closed.
/// Typing also finds files in the checkout you are in.
private struct SessionMenu: View {
    private enum Choice: Hashable {
        case session(UUID)
        case file(String)
    }

    @ObservedObject var session: Session
    @ObservedObject var store: SessionStore
    @ObservedObject var state: WindowState
    let openFile: (String) -> Void

    @State private var hovering = false
    @State private var query = ""
    /// The row the arrows or the mouse are on. Without one, Return goes to the first match.
    @State private var active: Choice?
    /// The checkout's files, listed each time the list opens, and the ones that match what is typed.
    @State private var files: (root: String, paths: [String]) = ("", [])
    @State private var hits: [String] = []
    @State private var listHeight: CGFloat = 0
    @FocusState private var searching: Bool

    private var palette: Palette { state.palette }
    private var open: Bool { state.switchingSession }

    var body: some View {
        let p = palette
        Button { state.switchingSession.toggle() } label: {
            HStack(spacing: 5) {
                Text(session.displayName)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(hovering || open || p.vivid ? p.text : p.muted)
            .padding(.horizontal, 8)
            .frame(height: 20)
            // With color, the title is a pill all the time, and lights up like a selected row.
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovering || open ? p.selection : p.vivid ? p.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietPress())
        .fixedSize()
        .onClickableHover { hovering = $0 }
        .hoverTip("Switch session (⌘P)")
        .popover(isPresented: $state.switchingSession, arrowEdge: .bottom) { list(p) }
        .onChange(of: state.switchingSession) { _, open in
            if open { listFiles() } else { (query, active, files, hits) = ("", nil, ("", []), []) }
        }
        .onChange(of: query) { _, query in (active, hits) = (nil, Files.search(files.paths, query)) }
    }

    /// Only in a git checkout, where git knows what to leave out.
    private func listFiles() {
        guard let root = session.topLevel else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let paths = Files.tracked(in: root)
            DispatchQueue.main.async {
                guard open else { return }
                (files, hits) = ((root, paths), Files.search(paths, query))
            }
        }
    }

    private func list(_ p: Palette) -> some View {
        let groups = matches
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(p.muted)
                // Return takes the first match, so a session is a few letters away.
                TextField(session.topLevel == nil ? "Search \(store.sessions.count) sessions" : "Search sessions and files", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onSubmit { highlighted.map(choose) }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                Text("⌘P").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
            }
            .padding(12)
            Rectangle().fill(p.line).frame(height: 1)
            ScrollViewReader { scroll in
                ScrollView {
                    // Not lazy: a lazy stack guesses its height from its first row, and a project header is taller than a session.
                    VStack(spacing: 1) {
                        ForEach(groups, id: \.key) { group in
                            if let key = group.key {
                                RepoHeader(name: URL(fileURLWithPath: key).lastPathComponent, palette: p)
                            }
                            ForEach(group.items) { item in
                                SessionChoice(
                                    session: item,
                                    current: item.id == store.selectedID,
                                    lit: highlighted == .session(item.id),
                                    shortcut: shortcut(for: item),
                                    palette: p,
                                    // Leaving a row hands Return back to the session you are in, as a menu would.
                                    hover: { inside in
                                        if inside { active = .session(item.id) } else if active == .session(item.id) { active = nil }
                                    },
                                    choose: { choose(.session(item.id)) })
                                .id(Choice.session(item.id))
                            }
                        }
                        // The file icons say what these rows are, so a line is enough to part them from the sessions.
                        if !hits.isEmpty && !groups.isEmpty {
                            Rectangle().fill(p.line).frame(height: 1).padding(.horizontal, 9).padding(.vertical, 5)
                        }
                        ForEach(hits, id: \.self) { path in
                            FileChoice(
                                path: path,
                                lit: highlighted == .file(path),
                                palette: p,
                                hover: { inside in
                                    if inside { active = .file(path) } else if active == .file(path) { active = nil }
                                },
                                choose: { choose(.file(path)) })
                            .id(Choice.file(path))
                        }
                        if groups.isEmpty && hits.isEmpty {
                            Text("Nothing matches.").foregroundStyle(p.muted).padding(.vertical, 12)
                        }
                    }
                    .padding(6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                // An exact height, since the popover only follows its rows when it has no other choice.
                .frame(height: min(listHeight, 320))
                // The arrows can go past the rows in view.
                .onChange(of: active) { _, row in if let row { scroll.scrollTo(row) } }
            }
        }
        .frame(width: 340)
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        // Boxed, the list is one more panel, in the color of the panels around the terminal.
        .background(p.boxed ? p.surface : p.background)
        .onAppear { searching = true }
    }

    /// The sidebar's groups, keeping only the sessions whose name, repo, branch or folder has every word typed.
    private var matches: [Grouping.Group<Session>] {
        let words = query.lowercased().split(separator: " ")
        return store.groups.compactMap { group in
            let items = group.items.filter { item in
                // With the home folder as ~, so your user name does not match every session.
                let folder = (item.directory as NSString).abbreviatingWithTildeInPath
                let text = [item.displayName, item.repoName ?? "", item.branch ?? "", folder].joined(separator: " ").lowercased()
                return words.allSatisfy(text.contains)
            }
            return items.isEmpty ? nil : Grouping.Group(key: group.key, items: items)
        }
    }

    private var shown: [Choice] { matches.flatMap(\.items).map { .session($0.id) } + hits.map(Choice.file) }

    /// The row Return opens: the one the arrows or the mouse are on, else where you are, else the first match.
    private var highlighted: Choice? {
        let shown = shown
        let current = query.isEmpty ? store.selectedID.map(Choice.session) : nil
        return shown.first { $0 == active } ?? shown.first { $0 == current } ?? shown.first
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let shown = shown
        guard !shown.isEmpty else { return .handled }
        let index = highlighted.flatMap(shown.firstIndex) ?? 0
        active = shown[(index + step + shown.count) % shown.count]
        return .handled
    }

    /// ⌘1 to ⌘9 as in the sidebar, shown until you type. A search changes the order, so the numbers would mislead.
    private func shortcut(for item: Session) -> String? {
        guard query.isEmpty, let index = store.ordered.firstIndex(where: { $0.id == item.id }), index < 9 else { return nil }
        return "⌘\(index + 1)"
    }

    private func choose(_ choice: Choice) {
        // Read before the list closes, which forgets the files.
        let root = files.root
        state.switchingSession = false
        switch choice {
        case .session(let id):
            if id != store.selectedID, let item = store.sessions.first(where: { $0.id == id }) { store.select(item) }
        case .file(let path):
            openFile(root + "/" + path)
        }
    }
}

/// A file in the title's list: its name, then the folder it is in.
private struct FileChoice: View {
    let path: String
    /// Under the arrows or the mouse.
    let lit: Bool
    let palette: Palette
    let hover: (Bool) -> Void
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 9) {
                // The room of a session's check and lamp, so every name starts at the same place.
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).hidden()
                Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(palette.muted).frame(width: 7)
                Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                Text((path as NSString).deletingLastPathComponent)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(lit ? palette.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietPress())
        .onClickableHover(hover)
    }
}

/// A session in the title's list: a check on the one you are in, its lamp, its name and branch, and its shortcut.
private struct SessionChoice: View {
    @ObservedObject var session: Session
    let current: Bool
    /// Under the arrows or the mouse.
    let lit: Bool
    let shortcut: String?
    let palette: Palette
    let hover: (Bool) -> Void
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 9) {
                // Always takes its room, so every name starts at the same place.
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.vivid ? palette.pull : palette.text)
                    .opacity(current ? 1 : 0)
                Lamp(activity: session.activity, selected: true, palette: palette)
                Text(session.displayName).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                if let branch = session.branch {
                    Text(branch).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(lit ? palette.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietPress())
        .onClickableHover(hover)
    }
}

extension View {
    /// Hover for anything clickable: runs `action` and shows the pointing hand while the mouse is over it.
    func onClickableHover(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(ClickableHover { inside in withAnimation(.easeOut(duration: 0.1)) { action(inside) } })
    }
}

/// A plain button that dims while the mouse is down, so a click is felt before its panel opens.
struct QuietPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Scroll views reset the cursor on every mouse move, so a hand pushed once on hover doesn't last in the sidebar or the tree.
/// macOS 15 has a pointer style for this. macOS 14 sets the hand again on each move.
private struct ClickableHover: ViewModifier {
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onHover(perform: action).pointerStyle(.link)
        } else {
            content
                .onHover { inside in
                    action(inside)
                    if !inside { NSCursor.arrow.set() }
                }
                .onContinuousHover { phase in
                    if case .active = phase { NSCursor.pointingHand.set() }
                }
        }
    }
}

/// The one close button, for panels, panes and rows. QuietButton draws the same in AppKit.
struct CloseButton: View {
    let help: String
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? palette.text : palette.muted)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? palette.raised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietPress())
        .onClickableHover { hovering = $0 }
        .hoverTip(help)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 26, height: 20)
                .foregroundStyle(active ? palette.accent : hovering ? palette.text : palette.muted)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering || active ? palette.raised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietPress())
        .onClickableHover { hovering = $0 }
        .hoverTip(help)
    }
}
