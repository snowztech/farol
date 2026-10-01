import SwiftUI

struct SidebarView: View {
    static let width: CGFloat = 224

    @ObservedObject var store: SessionStore
    @ObservedObject var state: WindowState
    let commands: Commands

    @State private var dragging: Session?
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
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(p.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(p.line).frame(width: 1) }
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
            if let branch = session.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .labelStyle(BranchLabelStyle())
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                    .truncationMode(.middle)
            } else if let location = session.location {
                Text(location)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                    .truncationMode(.head)
            }
        }
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
            .fill(selected ? palette.raised : hovering ? palette.raised.opacity(0.35) : .clear)
    }
}

/// The way to start a task, at the foot of the sidebar where the tasks live. Quiet until hovered.
private struct NewTaskRow: View {
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
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
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
            }
        }
        .foregroundStyle(hovering ? palette.text : palette.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? palette.raised.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onClickableHover { hovering = $0 }
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
            .foregroundStyle(palette.muted)
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
            case .waiting:
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

/// A small glyph tight against the branch name.
private struct BranchLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .medium))
            configuration.title
        }
    }
}
