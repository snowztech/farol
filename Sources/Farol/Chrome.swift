import FarolCore
import SwiftUI

/// UI state shared by the SwiftUI pieces of the window.
final class WindowState: ObservableObject {
    @Published var palette: Palette
    @Published var showingSettings = false
    /// Full screen has no traffic lights, so the title bar buttons take their place.
    @Published var fullScreen = false
    /// The selected session is over ssh, so the panels have nothing local to show.
    @Published var remote = false
    var noRepoMessage: String { remote ? "Not available over ssh." : "Not a git repository." }
    var noRepoSymbol: String { remote ? "network" : "folder.badge.questionmark" }
    /// Kept here so the About menu item can open settings on its page.
    @Published var settingsSection = SettingsPage.Section.terminal
    /// The three column merge view replaces the terminal while git is stopped on conflicts.
    @Published var showingMerge = false
    /// The session list under the title is open, from a click or ⌘P.
    @Published var switchingSession = false
    /// The files panel shows Find in Files instead of the tree, from ⇧⌘F or its magnifier.
    @Published var filesSearching = false
    /// Counts each ⇧⌘F, so one with the panel already searching puts the cursor back in its field.
    @Published var filesSearchFocus = 0
    /// Mirrors the sidebar and the files panel, so the top bar can match the columns below it.
    @Published var sidebarVisible = true
    @Published var sidebarWidth = SidebarView.defaultWidth
    @Published var filesVisible = false
    /// The files panel's width while open, which you can drag.
    @Published var filesWidth = FilesPanel.defaultWidth
    @Published var graphVisible = false
    /// Zero while the graph panel is closed.
    @Published var graphWidth: CGFloat = 0
    /// Zero while the review panel is closed.
    @Published var reviewWidth: CGFloat = 0
    /// The review fills the window. Its width above stays what it goes back to.
    @Published var reviewExpanded = false
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
    let newSessionIn: (String) -> Void
    let runCommand: (ProjectCommand) -> Void
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
                    SessionMenu(session: session, store: store, state: state, commands: commands)
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
                Spacer().frame(width: state.fullScreen ? 8 : 72)
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
        (state.sidebarVisible ? state.sidebarWidth : 0) + (filesVisible ? state.filesWidth : 0)
    }

    // The merge view and settings cover every panel but the sidebar, so the bar is laid out as if they were closed.
    private var covered: Bool { state.showingMerge || state.showingSettings }
    private var filesVisible: Bool { state.filesVisible && !covered }
    private var reviewWidth: CGFloat { covered ? 0 : state.reviewWidth }
    private var graphWidth: CGFloat { covered ? 0 : state.graphWidth }
    private var expanded: Bool { !covered && state.reviewExpanded }

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
            Rectangle().fill(p.panel).frame(width: state.sidebarVisible ? state.sidebarWidth - 1 : 0)
            Rectangle().fill(p.line).frame(width: state.sidebarVisible ? 1 : 0)
            Rectangle().fill(p.panel).frame(width: filesVisible ? state.filesWidth - 1 : 0)
            Rectangle().fill(p.line).frame(width: filesVisible ? 1 : 0)
            Rectangle().fill(p.background)
            // An expanded review runs on where the terminal was, with no edge between.
            Rectangle().fill(p.line).frame(width: reviewWidth > 0 && !expanded ? 1 : 0)
            Rectangle().fill(p.background).frame(width: max(reviewWidth - 1, 0))
            Rectangle().fill(p.line).frame(width: graphWidth > 0 ? 1 : 0)
            Rectangle().fill(p.panel).frame(width: max(graphWidth - 1, 0))
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

/// "+821 −61 ⛬": the counts open the review, the graph icon opens the graph.
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
        let counts = !review.total.isEmpty || review.isOpen
        let stopped = merge.operation != nil
        if !counts, !stopped, session.checkout != nil || state.graphVisible {
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
                // In the order the panels open below, review then graph, so the graph icon also keeps its place by the gear.
                if counts {
                    // Over a commit or a request it isn't lit: a click there brings your changes back.
                    Half(active: review.isOpen && review.showsYours, help: "Review changes (⌥⌘R)", palette: p, action: changes) { _ in
                        Counts(added: review.total.added, removed: review.total.removed, palette: p)
                    }
                }
                Half(active: state.graphVisible, help: "Git graph (⌥⌘G)", palette: p, action: graph) { color in
                    // The size of the gear next to it.
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(color)
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
/// The list is a panel of its own under the title bar, like Go to Line, rather than a popover, whose arrow tied it to the title as a menu.
private struct SessionMenu: View {
    @ObservedObject var session: Session
    @ObservedObject var store: SessionStore
    @ObservedObject var state: WindowState
    let commands: Commands

    @State private var hovering = false
    /// Where the title sits across the window. It is centered between the open panels, so the list is centered under it rather than on the window.
    @State private var titleMidX: CGFloat = 0
    /// A click on the title closes the list before the button sees it, which would open it again, so a close just before counts.
    @State private var closedAt = Date.distantPast

    private var open: Bool { state.switchingSession }

    var body: some View {
        let p = state.palette
        Button {
            guard Date().timeIntervalSince(closedAt) > 0.3 else { return }
            state.switchingSession.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(session.displayName)
                // What the sidebar row says under its name, so two sessions both called "dev" can be told apart here too.
                if let detail = session.serverWindow == nil ? (session.remoteLocation ?? session.branch ?? session.location) : nil {
                    Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted.opacity(0.8))
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 220)
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(hovering || open ? p.text : p.muted)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering || open ? p.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietPress())
        .fixedSize()
        .onClickableHover { hovering = $0 }
        .hoverTip("Switch session (⌘P)")
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { titleMidX = $0 }
        .onChange(of: state.switchingSession) { _, open in if open { present() } else { FloatingPanel.dismiss() } }
    }

    private func present() {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return state.switchingSession = false }
        // Dropping from the title, the only centered thing in the bar and the one the eye lines it up with.
        let (midX, frame, margin) = (titleMidX, window.frame, CGFloat(16))
        let top = frame.maxY - MainWindowController.topBarHeight - 6
        // Inside the window whatever its size: as wide as there is room for, and the list as tall as what is left under the search and above the footer.
        let width = min(SessionPalette.width, frame.width - 2 * margin)
        let listHeight = max(top - frame.minY - margin - SessionPalette.chrome, 90)
        FloatingPanel.show(palette: state.palette, over: window, place: { size, _ in
            // Under the title, or as near as the window's edges allow.
            let x = min(max(frame.minX + midX - size.width / 2, frame.minX + margin), frame.maxX - margin - size.width)
            return NSPoint(x: x, y: top - size.height)
        }, dismissed: {
            closedAt = Date()
            state.switchingSession = false
        }) { _ in
            SessionPalette(session: session, store: store, state: state, commands: commands, width: width, maxListHeight: listHeight)
        }
    }
}

/// What the title's list holds: the sessions, then once you type, the project's commands and the files around you.
private struct SessionPalette: View {
    private enum Choice: Hashable {
        case session(UUID)
        case command(ProjectCommand)
        case file(String)
    }

    @ObservedObject var session: Session
    @ObservedObject var store: SessionStore
    @ObservedObject var state: WindowState
    let commands: Commands
    var width = SessionPalette.width
    var maxListHeight: CGFloat = 400

    /// Wide enough for a file's folder and a command's text beside its name, in a window that has the room.
    static let width: CGFloat = 560
    /// The search above the list and the footer below it, which a short window still has to fit.
    static let chrome: CGFloat = 90

    @State private var query = ""
    /// The row the arrows or the mouse are on. Without one, Return goes to the first match.
    @State private var active: Choice?
    /// The files and folders around you, listed each time the list opens, and the ones that match what is typed.
    @State private var files: (root: String, paths: [String]) = ("", [])
    @State private var hits: [String] = []
    /// What the project defines to run, in its Makefile, package.json or justfile, read each time the list opens.
    @State private var projectCommands: [ProjectCommand] = []
    @State private var listHeight: CGFloat = 0
    /// The arrows moved the highlight, so the list follows it. The mouse moving it must not scroll the row out from under it.
    @State private var steering = false
    @FocusState private var searching: Bool

    private var palette: Palette { state.palette }
    /// The width of the column the search glass, the lamps and the file and command icons share.
    static let icon: CGFloat = 16

    private func listFiles() {
        let root = session.topLevel ?? session.directory
        // Over ssh the shell is on the server, where the Mac's folders mean nothing.
        let (folder, top, local) = (session.directory, session.topLevel, !session.isRemote)
        DispatchQueue.global(qos: .userInitiated).async {
            let paths = Files.searchable(in: root)
            let found = local ? ProjectCommands.find(in: folder, top: top, globalDirectory: ProjectCommands.globalDirectory) : []
            DispatchQueue.main.async {
                guard state.switchingSession else { return }
                (files, hits, projectCommands) = ((root, paths), Files.search(paths, query), found)
            }
        }
    }

    /// Only once you type, like the files, so the list you open stays the sessions.
    private var commandHits: [ProjectCommand] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        return projectCommands.filter { command in
            let text = "\(command.name) \(command.command) \(command.source)".lowercased()
            return words.allSatisfy(text.contains)
        }
    }

    var body: some View {
        let p = palette
        let groups = matches
        return VStack(spacing: 0) {
            HStack(spacing: 9) {
                // In the rows' icon column, so the search and every name start at the same place.
                Image(systemName: "magnifyingglass").foregroundStyle(p.muted).frame(width: Self.icon)
                // A step above the rows, since it's what you look at first.
                TextField("Search sessions, files and commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searching)
                    .onSubmit { highlighted.map(choose) }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            Rectangle().fill(p.line).frame(height: 1)
            ScrollViewReader { scroll in
                ScrollView {
                    // Not lazy: a lazy stack guesses its height from its first row, and a project header is taller than a session.
                    VStack(spacing: 1) {
                        ForEach(groups, id: \.key) { group in
                            if let key = group.key {
                                RepoHeader(name: URL(fileURLWithPath: key).lastPathComponent, palette: p, first: group.key == groups.first?.key)
                            }
                            ForEach(group.items) { item in
                                SessionChoice(
                                    session: item,
                                    current: item.id == store.selectedID,
                                    lit: highlighted == .session(item.id),
                                    shortcut: shortcut(for: item),
                                    palette: p,
                                    hover: { inside in if inside { (active, steering) = (.session(item.id), false) } },
                                    choose: { choose(.session(item.id)) })
                                .id(Choice.session(item.id))
                            }
                        }
                        let commandRows = commandHits
                        // Named like the projects above them, so every part of the list says what it holds.
                        // A section that opens the list sits as close under the search as a session would.
                        if !commandRows.isEmpty { RepoHeader(name: "Commands", palette: p, first: groups.isEmpty) }
                        ForEach(commandRows, id: \.self) { command in
                            CommandChoice(
                                command: command,
                                lit: highlighted == .command(command),
                                palette: p,
                                hover: { inside in if inside { (active, steering) = (.command(command), false) } },
                                choose: { choose(.command(command)) })
                            .id(Choice.command(command))
                        }
                        if !hits.isEmpty { RepoHeader(name: "Files", palette: p, first: groups.isEmpty && commandRows.isEmpty) }
                        ForEach(hits, id: \.self) { path in
                            FileChoice(
                                path: path,
                                lit: highlighted == .file(path),
                                palette: p,
                                hover: { inside in if inside { (active, steering) = (.file(path), false) } },
                                choose: { choose(.file(path)) })
                            .id(Choice.file(path))
                        }
                        if groups.isEmpty && commandRows.isEmpty && hits.isEmpty {
                            Text("Nothing matches “\(query)”.").foregroundStyle(p.muted).padding(.vertical, 12)
                        }
                    }
                    .padding(6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                // An exact height, which the panel follows as rows come and go.
                .frame(height: min(listHeight, maxListHeight))
                // Crossing the gaps and headers between rows keeps the highlight. Leaving the list hands Return back to the session you are in, as a menu would.
                .onHover { inside in if !inside { active = nil } }
                // The arrows can go past the rows in view.
                .onChange(of: active) { _, row in if steering, let row { scroll.scrollTo(row) } }
            }
            Rectangle().fill(p.line).frame(height: 1)
            footer(p)
        }
        .frame(width: width)
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .onAppear {
            searching = true
            listFiles()
        }
        .onChange(of: query) { _, query in (active, hits) = (nil, Files.search(files.paths, query)) }
    }

    /// The keys, and what Return does on the row it would open, said once here rather than inside the row as you move.
    private func footer(_ p: Palette) -> some View {
        HStack(spacing: 14) {
            Text("↑↓ to move")
            Text("esc to close")
            Spacer(minLength: 8)
            if let action = highlighted.map(action) {
                Text("\(action) \(Text(Image(systemName: "return")).font(.system(size: 9)))").foregroundStyle(p.text)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(p.muted)
        .padding(.horizontal, 15)
        .frame(height: 30)
    }

    /// What Return does on a row, which differs by kind: running something, or a folder opening a session, is not what a list leads you to expect.
    private func action(_ choice: Choice) -> String {
        switch choice {
        case .session(let id): id == store.selectedID ? "Stay here" : "Switch to session"
        case .command: session.panes.focused.runsProgram ? "Run in a new pane" : "Run"
        case .file(let path): path.hasSuffix("/") ? "Open as a new session" : "Open file"
        }
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

    private var shown: [Choice] { matches.flatMap(\.items).map { .session($0.id) } + commandHits.map(Choice.command) + hits.map(Choice.file) }

    /// The row Return opens: the one the arrows or the mouse are on, else where you are.
    /// A search is for going somewhere else, so it starts on the first match that is not where you are.
    private var highlighted: Choice? {
        let shown = shown
        let current = store.selectedID.map(Choice.session)
        return shown.first { $0 == active } ?? shown.first { query.isEmpty ? $0 == current : $0 != current } ?? shown.first
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let shown = shown
        guard !shown.isEmpty else { return .handled }
        let index = highlighted.flatMap(shown.firstIndex) ?? 0
        steering = true
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
        case .command(let command):
            commands.runCommand(command)
        case .file(let path):
            // A folder has nothing to show in a pane, so it opens as a session of its own.
            if path.hasSuffix("/") { commands.newSessionIn(root + "/" + path.dropLast()) } else { commands.openFile(root + "/" + path) }
        }
    }
}

/// What every row of the ⌘P list shares: its height, inset, highlight and hover, so sessions, commands and files read as one list.
private struct PaletteRow<Content: View>: View {
    /// Under the arrows or the mouse.
    let lit: Bool
    let palette: Palette
    let hover: (Bool) -> Void
    let choose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 9) { content }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lit ? palette.selection : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietPress())
        .onClickableHover(hover)
    }
}

/// A command the project defines: its name, then what it types.
private struct CommandChoice: View {
    let command: ProjectCommand
    let lit: Bool
    let palette: Palette
    let hover: (Bool) -> Void
    let choose: () -> Void

    var body: some View {
        PaletteRow(lit: lit, palette: palette, hover: hover, choose: choose) {
            Image(systemName: "play").font(.system(size: 9)).foregroundStyle(palette.muted).frame(width: SessionPalette.icon)
            Text(command.name).lineLimit(1).layoutPriority(1)
            Text(command.displayCommand)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
        }
        .hoverTip(command.global ? "Available in all projects" : "\(command.source) in \((command.folder as NSString).abbreviatingWithTildeInPath)")
    }
}

/// A file or a folder: its name, then the folder it is in.
private struct FileChoice: View {
    let path: String
    let lit: Bool
    let palette: Palette
    let hover: (Bool) -> Void
    let choose: () -> Void

    var body: some View {
        PaletteRow(lit: lit, palette: palette, hover: hover, choose: choose) {
            FileIcon(path: path).font(.system(size: 11)).foregroundStyle(palette.muted).frame(width: SessionPalette.icon)
            Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            Text((path as NSString).deletingLastPathComponent)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
        }
    }
}

/// A session: its lamp, its name and branch, a check on the one you are in, and its shortcut.
private struct SessionChoice: View {
    @ObservedObject var session: Session
    let current: Bool
    let lit: Bool
    let shortcut: String?
    let palette: Palette
    let hover: (Bool) -> Void
    let choose: () -> Void

    var body: some View {
        PaletteRow(lit: lit, palette: palette, hover: hover, choose: choose) {
            Lamp(activity: session.activity, selected: true, palette: palette).frame(width: SessionPalette.icon)
            Text(session.displayName).lineLimit(1).truncationMode(.tail).layoutPriority(1)
            if let branch = session.remoteLocation ?? session.branch {
                // A long name leaves the branch room for a lone "…", so it shows whole or not at all.
                ViewThatFits(in: .horizontal) {
                    Text(branch).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted).fixedSize()
                    EmptyView()
                }
            }
            Spacer(minLength: 8)
            if session.isWorktreeCheckout {
                Badge(text: "worktree", small: true, palette: palette)
                    .hoverTip("Worktree · \(session.topLevel ?? session.taskFolder ?? session.directory)")
            }
            // At the end, by the shortcut, so it doesn't push every name in the list to the right.
            if current {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.text)
            }
            if let shortcut {
                Text(shortcut).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted).fixedSize()
            }
        }
    }
}

extension View {
    /// Hover for anything clickable: runs `action` and shows the pointing hand while the mouse is over it.
    func onClickableHover(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(ClickableHover { inside in withAnimation(.easeOut(duration: 0.1)) { action(inside) } })
    }
}

/// What a panel shows when it has nothing to show: a quiet symbol and a line, in the middle of the panel.
struct EmptyState: View {
    let symbol: String
    let text: String
    let palette: Palette

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(palette.muted)
                .frame(width: 48, height: 48)
                .background(palette.raised.opacity(0.7), in: Circle())
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A short word in a soft capsule. With a tint it is a state, like Connected in green. Without, it names a kind of thing, like worktree.
struct Badge: View {
    let text: String
    var tint: Color? = nil
    /// A dot before the word, for a state that can change.
    var dot = false
    /// Small sits beside a name in a list. Regular sits on the right of a row in Settings.
    var small = false
    let palette: Palette

    var body: some View {
        let color = tint ?? palette.muted
        HStack(spacing: 5) {
            if dot { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text).font(.system(size: small ? 10 : 12, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, small ? 6 : 9)
        .frame(height: small ? 16 : 24)
        .background(color.opacity(tint == nil ? 0.12 : 0.15), in: Capsule())
        .fixedSize()
    }
}

/// Settings → Appearance → Animations. Off, or with Reduce Motion on in macOS, panels and highlights change at once.
/// The agent lamps keep moving, since their motion is how a waiting agent asks for you.
enum Motion {
    static let key = "appearance.animations"

    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool ?? true) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// A plain button that dims and shrinks a little while the mouse is down, so a click is felt before its panel opens.
struct QuietPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && Motion.enabled ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
    /// A plus for the same small button that adds instead.
    var symbol = "xmark"
    let help: String
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? palette.text : palette.muted)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? palette.raised : .clear))
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
                .font(.system(size: 13, weight: .medium))
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
