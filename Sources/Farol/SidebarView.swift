import SwiftUI

struct SidebarView: View {
    static let width: CGFloat = 224

    @ObservedObject var store: SessionStore
    @ObservedObject var state: WindowState
    let commands: Commands

    @State private var dragging: Session?

    var body: some View {
        let p = state.palette
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(store.sessions) { session in
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
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(palette.muted)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close session (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background { background }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        // Alongside the single tap, not instead of it, so selecting never waits for a possible second click.
        .simultaneousGesture(TapGesture(count: 2).onEnded { startEditing() })
        .onHover { hovering = $0 }
        .help(session.directory)
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

    /// Selection stays neutral. The accent is reserved for "this session needs you".
    private var background: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(selected ? palette.raised : hovering ? palette.raised.opacity(0.5) : .clear)
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
        withAnimation(.easeOut(duration: 0.15)) { store.move(dragging, to: index) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Dim while the program runs. Lit and slowly pulsing when the session wants you.
private struct Lamp: View {
    let activity: Session.Activity
    /// A session you are looking at has no need to pulse.
    let selected: Bool
    let palette: Palette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var spin = false

    var body: some View {
        ZStack {
            switch activity {
            case .idle:
                // Nothing to report, so nothing drawn. The frame keeps titles aligned.
                Color.clear
            case .working:
                // Moving means busy, the way a spinner does.
                Circle()
                    .trim(from: 0, to: reduceMotion ? 1 : 0.7)
                    .stroke(palette.accent.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                    }
                    .onDisappear { spin = false }
            case .waiting:
                if !selected && !reduceMotion {
                    Circle()
                        .fill(palette.accent)
                        .scaleEffect(pulse ? 2.6 : 1)
                        .opacity(pulse ? 0 : 0.5)
                        .onAppear {
                            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
                        }
                        .onDisappear { pulse = false }
                }
                Circle().fill(palette.accent).padding(1.5)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(palette.accent)
            }
        }
        .frame(width: 10, height: 10)
        .help(help)
    }

    private var help: String {
        switch activity {
        case .idle: ""
        case .working: "Agent working"
        case .waiting: "Waiting for you"
        case .done: "Agent finished"
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
