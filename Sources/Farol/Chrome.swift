import SwiftUI

/// UI state shared by the SwiftUI pieces of the window.
final class WindowState: ObservableObject {
    @Published var palette: Palette
    @Published var showingSettings = false
    /// Mirrors the sidebar, so the top bar can match the columns below it.
    @Published var sidebarVisible = true
    let ghosttyConfigPreview: ThemeColors

    init(palette: Palette, ghosttyConfigPreview: ThemeColors) {
        self.palette = palette
        self.ghosttyConfigPreview = ghosttyConfigPreview
    }
}

struct Commands {
    let newSession: () -> Void
    let newTask: () -> Void
    let closeSession: (Session) -> Void
    let toggleSidebar: () -> Void
    let toggleSettings: () -> Void
    let titleBarDoubleClick: () -> Void
}

struct TopBar: View {
    @ObservedObject var state: WindowState
    @ObservedObject var store: SessionStore
    let commands: Commands

    var body: some View {
        let p = state.palette
        ZStack {
            Group {
                if state.showingSettings {
                    Text("Settings")
                } else if let session = store.selected {
                    SessionTitle(session: session)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(p.muted)
            .lineLimit(1)
            .padding(.horizontal, 160)

            HStack(spacing: 2) {
                // Room for the traffic lights.
                Spacer().frame(width: 72)
                IconButton(symbol: "sidebar.left", help: "Toggle sidebar (⌘B)", palette: p, action: commands.toggleSidebar)
                IconButton(symbol: "plus", help: "New session (⌘T)", palette: p, action: commands.newSession)
                Spacer()
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

    /// No rule under the bar: each part takes the color of the column below, so the terminal reaches the top edge.
    private func columns(_ p: Palette) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(p.surface)
                .frame(width: state.sidebarVisible ? SidebarView.width - 1 : 0)
            Rectangle().fill(p.line)
                .frame(width: state.sidebarVisible ? 1 : 0)
            Rectangle().fill(p.background)
        }
    }
}

private struct SessionTitle: View {
    @ObservedObject var session: Session
    var body: some View { Text(session.displayName) }
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
        .onHover { hovering = $0 }
        .help(help)
    }
}
