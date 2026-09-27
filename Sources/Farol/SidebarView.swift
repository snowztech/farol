import SwiftUI

struct SidebarView: View {
    static let width: CGFloat = 224

    @ObservedObject var store: SessionStore
    @ObservedObject var state: WindowState

    var body: some View {
        let p = state.palette
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(store.sessions) { session in
                    SessionRow(
                        session: session,
                        selected: session.id == store.selectedID && !state.showingSettings,
                        palette: p,
                        onSelect: { store.select(session) },
                        onClose: { store.close(session) })
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
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Lamp(lit: session.status == .needsAttention, palette: palette)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? palette.text : palette.text.opacity(0.78))
                if let subtitle = session.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.muted)
                        .truncationMode(.head)
                }
            }
            .lineLimit(1)

            Spacer(minLength: 0)

            if hovering {
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
        .onHover { hovering = $0 }
        .help(session.directory)
    }

    /// Selection stays neutral. The accent is reserved for "this session needs you".
    private var background: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(selected ? palette.raised : hovering ? palette.raised.opacity(0.5) : .clear)
    }
}

/// Dim while the program runs. Lit and slowly pulsing when the session wants you.
private struct Lamp: View {
    let lit: Bool
    let palette: Palette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            if lit && !reduceMotion {
                Circle()
                    .fill(palette.accent)
                    .scaleEffect(pulse ? 2.6 : 1)
                    .opacity(pulse ? 0 : 0.5)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
                    }
                    .onDisappear { pulse = false }
            }
            Circle().fill(lit ? palette.accent : palette.muted.opacity(0.45))
        }
        .frame(width: 7, height: 7)
    }
}
