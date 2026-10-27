import SwiftUI

struct SidebarView: View {
    static let defaultWidth: CGFloat = 224

    @ObservedObject var store: SessionStore
    @ObservedObject var state: WindowState
    let commands: Commands
    let resize: (CGFloat) -> Void

    @State private var dragging: Session?
    @State private var dragStart: CGFloat?
    /// Only read so the sidebar redraws when the setting changes. The store applies it.
    @AppStorage(SessionStore.groupByRepoKey) private var groupByRepo = false

    var body: some View {
        let p = state.palette
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.groups, id: \.key) { group in
                        if let key = group.key {
                            RepoHeader(name: URL(fileURLWithPath: key).lastPathComponent, palette: p)
                        }
                        ForEach(group.items) { session in
                            SessionRow(
                                session: session,
                                selected: session.id == store.selectedID && !state.showingSettings,
                                palette: p,
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
            }
            // Pinned below the list, so it stays in the same place however many sessions there are.
            NewTaskRow(palette: p, action: commands.newTask)
                .padding(8)
        }
        // Fixed width, so collapsing the sidebar clips it instead of reflowing every row.
        .frame(width: state.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(p.surface)
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
}

private struct SessionRow: View {
    @ObservedObject var session: Session
    let selected: Bool
    let palette: Palette
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
        .padding(.vertical, 7)
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
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: fieldFocused) { _, focused in if !focused { commit() } }
            } else {
                Text(session.displayName)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? palette.text : palette.text.opacity(0.78))
            }
            if let waiting = session.waitingFor {
                // In place of the branch while the agent waits, so the row says what for without being opened.
                Text(waiting)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.muted)
                    .truncationMode(.tail)
                    .hoverTip(waiting)
            } else {
                HStack(spacing: 6) {
                    if let branch = gitLine {
                        HStack(spacing: 4) {
                            BranchMark(color: palette.muted)
                            Text(branch).truncationMode(.middle)
                        }
                    } else if let location = session.remoteLocation ?? session.location {
                        Text(location).truncationMode(.head)
                    }
                    // The branch gives way first, so a port is always whole.
                    Spacer(minLength: 4)
                    ForEach(session.ports.prefix(2), id: \.self) { PortLink(port: $0, palette: palette) }
                    if session.ports.count > 2 { Text(verbatim: "+\(session.ports.count - 2)").fixedSize() }
                    if session.isWorktreeCheckout {
                        Text("worktree")
                            .foregroundStyle(palette.muted.opacity(0.65))
                            .fixedSize()
                            .padding(.leading, 4)
                            .hoverTip("Worktree · \(session.topLevel ?? session.taskFolder ?? session.directory)")
                    }
                }
                .font(.system(size: 10.5, design: .monospaced))
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

    /// Selection stays neutral, so color only ever means agent status.
    private var background: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(selected ? palette.selection : hovering ? palette.hover : .clear)
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
                .frame(width: 7)
            Text("New task")
                .font(.system(size: 12.5))
            Spacer(minLength: 0)
            if hovering {
                Text("⇧⌘N")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(palette.muted)
            }
        }
        .foregroundStyle(hovering || palette.vivid ? palette.text : palette.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // With color, starting a task is the one filled button in the sidebar.
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(palette.vivid ? palette.selection.opacity(hovering ? 1 : 0.6) : hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
    }
}

/// A repo's name above its sessions, only there once sessions span several repos.
struct RepoHeader: View {
    let name: String
    let palette: Palette

    var body: some View {
        Text(name.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(palette.vivid ? palette.pull : palette.muted)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
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
        .frame(width: 7, height: 7)
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
private struct BranchMark: View {
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
