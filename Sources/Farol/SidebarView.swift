import Combine
import SwiftUI

struct SidebarView: View {
    static let defaultWidth: CGFloat = 224

    @ObservedObject var store: SessionStore
    @ObservedObject var state: WindowState
    let commands: Commands
    let resize: (CGFloat) -> Void

    @State private var dragging: Session?
    /// The selection's highlight is one shape that moves to the row you pick.
    @Namespace private var selection
    @State private var dragStart: CGFloat?
    /// Only read so the sidebar redraws when the setting changes. The store applies it.
    @AppStorage(SessionStore.groupByRepoKey) private var groupByRepo = false
    /// The projects folded shut, by repo path, one per line.
    @AppStorage("sidebar.folded") private var folded = ""

    var body: some View {
        let p = state.palette
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.groups, id: \.key) { group in
                        let name = group.key.map { URL(fileURLWithPath: $0).lastPathComponent }
                        let shut = group.key.map(isFolded) ?? false
                        if let key = group.key, let name {
                            ProjectHeader(name: name, sessions: group.items, folded: shut,
                                          holdsSelection: group.items.contains { $0.id == store.selectedID }, palette: p,
                                          onToggle: { toggleFold(key) }, onNew: { commands.newSessionIn(key) })
                        }
                        ForEach(shut ? [] : group.items) { session in
                            SessionRow(
                                session: session,
                                selected: session.id == store.selectedID && !state.showingSettings,
                                palette: p,
                                highlight: selection,
                                // Reselecting would pull focus back into the terminal, which a rename would lose.
                                onSelect: {
                                    if session.id != store.selectedID || state.showingSettings { store.select(session) }
                                },
                                onRename: { store.rename(session, to: $0) },
                                onClose: { commands.closeSession(session) })
                            .onDrag {
                                dragging = session
                                return NSItemProvider(object: session.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: Reorder(target: session, store: store, dragging: $dragging))
                        }
                    }
                }
                .padding(8)
                .animation(Motion.enabled ? .spring(response: 0.32, dampingFraction: 0.86) : nil, value: store.selectedID)
            }
            // Pinned below the list, so it stays in the same place however many sessions there are.
            NewTaskRow(palette: p, action: commands.newTask)
                .padding(8)
        }
        // Reaching a session in a folded project, with ⌘1 to ⌘9, a notification or a new session, opens the project so the row is there.
        // A new session's repo is found a moment after it's selected, so the repo is watched too.
        .onChange(of: store.selectedID) { revealSelected() }
        .onChange(of: store.selected?.repoRoot) { revealSelected() }
        // Fixed width, so collapsing the sidebar clips it instead of reflowing every row.
        .frame(width: state.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(p.panel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(p.boxed ? .clear : p.line).frame(width: 1)
                .frame(width: 7, alignment: .trailing)
                .contentShape(Rectangle())
                .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
                .gesture(DragGesture(coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStart ?? state.sidebarWidth
                        dragStart = start
                        resize(start + drag.translation.width)
                    }
                    .onEnded { _ in dragStart = nil })
        }
    }

    private func revealSelected() {
        guard let key = store.selected?.repoRoot, isFolded(key) else { return }
        toggleFold(key)
    }

    private func isFolded(_ key: String) -> Bool {
        folded.split(separator: "\n").contains { $0 == key }
    }

    private func toggleFold(_ key: String) {
        var keys = folded.split(separator: "\n").map(String.init)
        if let index = keys.firstIndex(of: key) { keys.remove(at: index) } else { keys.append(key) }
        withAnimation(.easeOut(duration: 0.15)) { folded = keys.joined(separator: "\n") }
    }
}

private struct SessionRow: View {
    @ObservedObject var session: Session
    let selected: Bool
    let palette: Palette
    let highlight: Namespace.ID
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onClose: () -> Void

    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Lamp(activity: session.activity, selected: selected, palette: palette)

            labels.lineLimit(1)

            Spacer(minLength: 0)

            if hovering && !editing {
                CloseButton(help: "Close session (⌘W)", palette: palette, action: onClose)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background { background }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        // Alongside the single tap, not instead of it, so selecting never waits for a possible second click.
        .simultaneousGesture(TapGesture(count: 2).onEnded { startEditing() })
        .onClickableHover { hovering = $0 }
        .contextMenu {
            Button("Rename", action: startEditing)
            Button("Close Session", action: onClose)
            // Over ssh the folder is on the server, where the Mac's apps can't reach it.
            if !session.isRemote {
                Divider()
                OpenInItems(path: session.topLevel ?? session.directory)
            }
        }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 1) {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: fieldFocused) { _, focused in if !focused { commit() } }
            } else {
                let name = Text(session.displayName)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? palette.text : palette.text.opacity(0.8))
                if session.isWorktreeCheckout {
                    // The name gives way first, so the tag stays whole and never shrinks to a stray "w…".
                    HStack(spacing: 6) {
                        name.lineLimit(1).truncationMode(.tail)
                        Badge(text: "worktree", small: true, palette: palette)
                            .layoutPriority(1)
                            .hoverTip("Worktree · \(session.topLevel ?? session.taskFolder ?? session.directory)")
                    }
                } else {
                    name
                }
            }
            if let waiting = session.waitingFor {
                // In place of the branch while the agent waits, so the row says what for without being opened.
                Text(waiting)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                    .truncationMode(.tail)
                    .hoverTip(waiting)
            } else {
                HStack(spacing: 6) {
                    // Ahead of the spacer, which would otherwise take half the room and cut the branch short.
                    Group {
                        if let branch = gitLine {
                            HStack(spacing: 4) {
                                BranchMark(color: palette.muted)
                                Text(branch).truncationMode(.middle)
                            }
                        } else if let location = session.remoteLocation ?? session.location {
                            Text(location).truncationMode(.head)
                        }
                    }
                    .layoutPriority(1)
                    // The branch gives way first, so a port is always whole.
                    Spacer(minLength: 4)
                    if let port = session.ports.first { PortLink(port: port, palette: palette) }
                    if session.ports.count > 1 {
                        Text(verbatim: "+\(session.ports.count - 1)")
                            .fixedSize()
                            .hoverTip("Also on " + session.ports.dropFirst().map { "localhost:\($0)" }.joined(separator: ", "))
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.muted)
            }
        }
    }

    /// The branch, and what is left to do while git is stopped. In the row's usual gray, since the lamp already asks for you.
    private var gitLine: String? {
        guard session.stopped != nil else { return session.remoteLocation == nil ? session.branch : nil }
        let left = session.conflicts == 0 ? "ready to continue"
            : "\(session.conflicts) \(session.conflicts == 1 ? "conflict" : "conflicts")"
        return [session.branch, left].compactMap { $0 }.joined(separator: " · ")
    }

    private func startEditing() {
        draft = session.displayName
        editing = true
        // The field only exists after this update, so focus it on the next turn.
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        onRename(draft)
    }

    /// Selection stays neutral, so color only ever means agent status. A faint edge lifts it off the panel.
    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if selected {
            GlassFill(palette: palette, color: palette.selection, shape: shape)
                .overlay(shape.strokeBorder(palette.line.opacity(palette.liquid ? 0 : 1)))
                .matchedGeometryEffect(id: "selection", in: highlight)
        } else {
            shape.fill(hovering ? palette.hover : .clear)
        }
    }
}

/// The way to start a task, at the foot of the sidebar where the tasks live. Quiet until hovered.
private struct NewTaskRow: View {
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(QuietPress())
            .onClickableHover { hovering = $0 }
    }

    private var label: some View {
        HStack(spacing: 10) {
            // Same width as the status dots, so the label lines up with session names.
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: Lamp.size)
            Text("New task")
                .font(.system(size: 13))
            Spacer(minLength: 0)
            if hovering {
                Text("⇧⌘N")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.muted)
            }
        }
        .foregroundStyle(hovering ? palette.text : palette.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
    }
}

/// A repo's name above its sessions, only there once sessions span several repos.
struct RepoHeader: View {
    let name: String
    let palette: Palette

    var body: some View {
        Text(name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.muted)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

/// A project's name above its sessions, the whole row a button that folds them away.
/// Folded, it shows how many there are and, in the lamp column, the most pressing lamp among them.
private struct ProjectHeader: View {
    let name: String
    let sessions: [Session]
    let folded: Bool
    /// Folded with the session on screen inside, it takes the selection's highlight so you can see where it went.
    let holdsSelection: Bool
    let palette: Palette
    let onToggle: () -> Void
    let onNew: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // The session lamps' column, so the project name lines up with session names.
            ZStack {
                if folded { FoldedLamp(sessions: sessions, palette: palette) }
            }
            .frame(width: Lamp.size)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? palette.text : palette.muted)
            if folded {
                Text(verbatim: "\(sessions.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.muted.opacity(0.7))
            }
            Spacer(minLength: 0)
            if hovering {
                CloseButton(symbol: "plus", help: "New session in \(name)", palette: palette, action: onNew)
            }
            // Faint while open, so the header still reads as one that folds, and full when folded or hovered.
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? palette.text : palette.muted)
                .rotationEffect(.degrees(folded ? 0 : 90))
                .frame(width: 20, height: 20)
                .opacity(hovering || folded ? 1 : 0.35)
        }
        .lineLimit(1)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            if folded && holdsSelection {
                GlassFill(palette: palette, color: palette.selection, shape: shape)
            } else {
                shape.fill(hovering ? palette.hover : .clear)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onClickableHover { hovering = $0 }
        .hoverTip(folded ? "Show \(name)'s sessions" : "Fold \(name)")
        .padding(.top, 10)
    }
}

/// The lamp a folded project shows for its sessions, so an agent waiting inside never goes unseen.
private struct FoldedLamp: View {
    let sessions: [Session]
    let palette: Palette

    /// Bumped whenever a session changes, since the header doesn't observe each one.
    @State private var changes = 0

    var body: some View {
        let _ = changes
        // Ordered by who needs you: git stopped, an agent asking, an agent finished, then one still working.
        let pressing: [Session.Activity] = [.stopped, .waiting, .done, .working]
        let activity = pressing.first { level in sessions.contains { $0.activity == level } } ?? .idle
        Lamp(activity: activity, selected: false, palette: palette)
            .onReceive(Publishers.MergeMany(sessions.map(\.objectWillChange))) { _ in changes += 1 }
    }
}

/// Moves the dragged session live as it passes over other rows.
private struct Reorder: DropDelegate {
    let target: Session
    let store: SessionStore
    @Binding var dragging: Session?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging !== target,
              let index = store.sessions.firstIndex(where: { $0 === target }) else { return }
        // A session's section comes from its folder, so it only moves within its own repo.
        let grouped = store.groups.contains { $0.key != nil }
        guard !grouped || dragging.repoRoot == target.repoRoot else { return }
        withAnimation(.easeOut(duration: 0.15)) { store.move(dragging, to: index) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Hollow when nothing is happening, breathing while the agent works, rippling when it waits for you, filled when it is done.
struct Lamp: View {
    /// Every column that lines up with the lamps uses this width.
    static let size: CGFloat = 7

    let activity: Session.Activity
    /// A session you are looking at has no need to ripple.
    let selected: Bool
    let palette: Palette

    var body: some View {
        ZStack {
            switch activity {
            case .idle: Circle().strokeBorder(palette.muted.opacity(0.5), lineWidth: 1.2)
            case .working: Breathing(color: palette.working)
            case .waiting, .stopped:
                // A ripple asks for attention, which a working dot never does.
                if !selected { Ripple(color: palette.waiting) }
                Circle().fill(palette.waiting)
            case .done: Circle().fill(palette.done)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .hoverTip(help)
    }

    private var help: String {
        switch activity {
        case .idle: ""
        case .working: "Working"
        case .waiting: "Waiting for your approval or an answer"
        case .done: "Done. Your turn"
        case .stopped: "Git stopped. Resolve and continue (⌥⌘M)"
        }
    }
}

/// Each animation keeps its own state, so switching between them always starts clean.
private struct Breathing: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .opacity(dim ? 0.25 : 0.9)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever()) { dim = true }
            }
    }
}

private struct Ripple: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var out = false

    var body: some View {
        Circle()
            .fill(color)
            .scaleEffect(out ? 2.6 : 1)
            .opacity(out ? 0 : (reduceMotion ? 0 : 0.5))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { out = true }
            }
    }
}

/// A port the session's programs listen on, muted like the branch until hovered, and opened in the browser on click.
private struct PortLink: View {
    let port: Int
    let palette: Palette

    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!)
        } label: {
            Text(verbatim: ":\(port)")
                .foregroundStyle(hovering ? palette.text : palette.muted)
                .underline(hovering)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onClickableHover { hovering = $0 }
        .hoverTip("Open localhost:\(port)")
    }
}

/// The system branch symbol's arrow draws too much attention beside a small branch name.
struct BranchMark: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let unit = size.width / 12
            var line = Path()
            line.move(to: CGPoint(x: 3 * unit, y: 2 * unit))
            line.addLine(to: CGPoint(x: 3 * unit, y: 10 * unit))
            line.move(to: CGPoint(x: 9 * unit, y: 2 * unit))
            line.addLine(to: CGPoint(x: 9 * unit, y: 4 * unit))
            line.addQuadCurve(to: CGPoint(x: 3 * unit, y: 8 * unit),
                              control: CGPoint(x: 9 * unit, y: 8 * unit))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: unit, lineCap: .round))
            for point in [CGPoint(x: 3 * unit, y: 2 * unit), CGPoint(x: 9 * unit, y: 2 * unit),
                          CGPoint(x: 3 * unit, y: 10 * unit)] {
                let dot = Path(ellipseIn: CGRect(x: point.x - 1.4 * unit, y: point.y - 1.4 * unit,
                                                 width: 2.8 * unit, height: 2.8 * unit))
                context.fill(dot, with: .color(color))
            }
        }
        .frame(width: 11, height: 11)
        .accessibilityHidden(true)
    }
}
