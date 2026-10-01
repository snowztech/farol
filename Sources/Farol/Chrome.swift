import FarolCore
import SwiftUI

/// UI state shared by the SwiftUI pieces of the window.
final class WindowState: ObservableObject {
    @Published var palette: Palette
    @Published var showingSettings = false
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
    let titleBarDoubleClick: () -> Void
}

struct TopBar: View {
    @ObservedObject var state: WindowState
    @ObservedObject var store: SessionStore
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var review: ReviewModel
    let commands: Commands

    var body: some View {
        let p = state.palette
        ZStack {
            Group {
                if state.showingSettings {
                    Text("Settings")
                } else if let session = store.selected {
                    SessionMenu(session: session, store: store, state: state)
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
            .padding(.trailing, p.boxed ? 0 : state.reviewWidth + state.graphWidth)

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
                    GitButton(session: session, state: state, review: review,
                              graph: commands.toggleGraph, changes: commands.toggleReview)
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
        (state.sidebarVisible ? SidebarView.width : 0) + (state.filesVisible ? FilesPanel.width : 0)
    }

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
            Rectangle().fill(p.surface).frame(width: state.filesVisible ? FilesPanel.width - 1 : 0)
            Rectangle().fill(p.line).frame(width: state.filesVisible ? 1 : 0)
            Rectangle().fill(p.background)
            Rectangle().fill(p.line).frame(width: state.reviewWidth > 0 ? 1 : 0)
            Rectangle().fill(p.background).frame(width: max(state.reviewWidth - 1, 0))
            Rectangle().fill(p.line).frame(width: state.graphWidth > 0 ? 1 : 0)
            Rectangle().fill(p.surface).frame(width: max(state.graphWidth - 1, 0))
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
        .buttonStyle(.plain)
        .onClickableHover { hovering = $0 }
        .hoverTip("Farol \(version) is available. Download it.")
    }
}

/// "⛬ +821 −61": the graph icon opens the graph, the counts open the review.
/// Only in a git repo, or while a panel is open so it can still be closed. The counts, and the pill around both, only when there are changes.
private struct GitButton: View {
    @ObservedObject var session: Session
    @ObservedObject var state: WindowState
    @ObservedObject var review: ReviewModel
    let graph: () -> Void
    let changes: () -> Void

    var body: some View {
        let p = state.palette
        let counts = !review.stat.isEmpty || review.isOpen
        if !counts, session.topLevel != nil || state.graphVisible {
            // Alone, the icon sits bare like the others in the title bar. A pill around it reads as switched on.
            IconButton(symbol: "point.3.connected.trianglepath.dotted", help: "Git graph (⌥⌘G)", active: state.graphVisible,
                       palette: p, action: graph)
        } else if counts {
            HStack(spacing: 0) {
                Half(active: state.graphVisible, help: "Git graph (⌥⌘G)", palette: p, action: graph) { color in
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(color)
                }
                if counts {
                    Rectangle().fill(p.line).frame(width: 1, height: 12)
                    Half(active: review.isOpen, help: "Review changes (⌥⌘R)", palette: p, action: changes) { _ in
                        Counts(added: review.stat.added, removed: review.stat.removed, palette: p)
                    }
                }
            }
            .font(.system(size: 11, weight: .medium))
            .background(p.raised.opacity(0.6), in: Capsule())
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(p.line))
            .padding(.trailing, 6)
        }
    }

    /// One clickable side of the pill, lit while hovered or while its panel is open.
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
                    .background(hovering || active ? palette.raised : .clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onClickableHover { hovering = $0 }
            .hoverTip(help)
        }
    }
}

/// The title opens a searchable list of every session, grouped like the sidebar, so you can switch with the sidebar closed.
private struct SessionMenu: View {
    @ObservedObject var session: Session
    @ObservedObject var store: SessionStore
    @ObservedObject var state: WindowState

    @State private var hovering = false
    @State private var query = ""
    /// The row the arrows or the mouse are on. Without one, Return goes to the first match.
    @State private var active: UUID?
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
        .buttonStyle(.plain)
        .fixedSize()
        .onClickableHover { hovering = $0 }
        .hoverTip("Switch session (⌘P)")
        .popover(isPresented: $state.switchingSession, arrowEdge: .bottom) { list(p) }
        .onChange(of: state.switchingSession) { _, open in if !open { (query, active) = ("", nil) } }
        .onChange(of: query) { _, _ in active = nil }
    }

    private func list(_ p: Palette) -> some View {
        let groups = matches
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(p.muted)
                // Return takes the first match, so a session is a few letters away.
                TextField("Search \(store.sessions.count) sessions", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onSubmit { highlighted.map(choose) }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                Text("⌘P").font(.system(size: 11.5)).foregroundStyle(p.muted)
            }
            .padding(12)
            Rectangle().fill(p.line).frame(height: 1)
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
                                lit: item.id == highlighted?.id,
                                shortcut: shortcut(for: item),
                                palette: p,
                                // Leaving a row hands Return back to the session you are in, as a menu would.
                                hover: { inside in
                                    if inside { active = item.id } else if active == item.id { active = nil }
                                },
                                choose: { choose(item) })
                        }
                    }
                    if groups.isEmpty {
                        Text("No session matches.").foregroundStyle(p.muted).padding(.vertical, 12)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 340)
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        // Boxed, the list is one more panel, in the color of the panels around the terminal.
        .background(p.boxed ? p.surface : p.background)
        .onAppear { searching = true }
    }

    /// The sidebar's groups, keeping only the sessions whose name, repo or branch has every word typed.
    private var matches: [Grouping.Group<Session>] {
        let words = query.lowercased().split(separator: " ")
        return store.groups.compactMap { group in
            let items = group.items.filter { item in
                let text = [item.displayName, item.repoName ?? "", item.branch ?? ""].joined(separator: " ").lowercased()
                return words.allSatisfy(text.contains)
            }
            return items.isEmpty ? nil : Grouping.Group(key: group.key, items: items)
        }
    }

    private var shown: [Session] { matches.flatMap(\.items) }

    /// The row Return opens: the one the arrows or the mouse are on, else where you are, else the first match.
    private var highlighted: Session? {
        let shown = shown
        return shown.first { $0.id == active } ?? shown.first { $0.id == store.selectedID && query.isEmpty } ?? shown.first
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let shown = shown
        guard !shown.isEmpty else { return .handled }
        let index = shown.firstIndex { $0.id == highlighted?.id } ?? 0
        active = shown[(index + step + shown.count) % shown.count].id
        return .handled
    }

    /// ⌘1 to ⌘9 as in the sidebar, shown until you type. A search changes the order, so the numbers would mislead.
    private func shortcut(for item: Session) -> String? {
        guard query.isEmpty, let index = store.ordered.firstIndex(where: { $0.id == item.id }), index < 9 else { return nil }
        return "⌘\(index + 1)"
    }

    private func choose(_ item: Session) {
        state.switchingSession = false
        if item.id != store.selectedID { store.select(item) }
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
                    Text(branch).font(.system(size: 11.5)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(palette.muted)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(lit ? palette.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onClickableHover(hover)
    }
}

extension View {
    /// Hover for anything clickable: runs `action` and shows the pointing hand while the mouse is over it.
    func onClickableHover(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(ClickableHover(action: action))
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
        .onClickableHover { hovering = $0 }
        .hoverTip(help)
    }
}
