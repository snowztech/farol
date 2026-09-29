import FarolCore
import SwiftUI

/// UI state shared by the SwiftUI pieces of the window.
final class WindowState: ObservableObject {
    @Published var palette: Palette
    @Published var showingSettings = false
    /// Mirrors the sidebar and the files panel, so the top bar can match the columns below it.
    @Published var sidebarVisible = true
    @Published var filesVisible = false
    /// Zero while the review panel is closed.
    @Published var reviewWidth: CGFloat = 0
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
    let toggleFiles: () -> Void
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
                    SessionTitle(session: session)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(p.muted)
            .lineLimit(1)
            // Centered over the content, between the open panels, so it never sits on a panel's edge.
            .padding(.horizontal, 120)
            .frame(maxWidth: .infinity)
            .padding(.leading, leftPanels)
            .padding(.trailing, state.reviewWidth)

            HStack(spacing: 2) {
                // Room for the traffic lights.
                Spacer().frame(width: 72)
                IconButton(symbol: "sidebar.left", help: "Toggle sidebar (⌘B)", active: state.sidebarVisible,
                           palette: p, action: commands.toggleSidebar)
                IconButton(symbol: "folder", help: "Files (⇧⌘E)", active: state.filesVisible,
                           palette: p, action: commands.toggleFiles)
                newSessionButton(p)
                Spacer()
                // Only there when the session has changes, like the Update button.
                if !review.stat.isEmpty || review.isOpen {
                    ReviewButton(stat: review.stat, active: review.isOpen, palette: p, action: commands.toggleReview)
                        .padding(.trailing, 6)
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
    private func columns(_ p: Palette) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(p.surface).frame(width: state.sidebarVisible ? SidebarView.width - 1 : 0)
            Rectangle().fill(p.line).frame(width: state.sidebarVisible ? 1 : 0)
            Rectangle().fill(p.surface).frame(width: state.filesVisible ? FilesPanel.width - 1 : 0)
            Rectangle().fill(p.line).frame(width: state.filesVisible ? 1 : 0)
            Rectangle().fill(p.background)
            Rectangle().fill(p.line).frame(width: state.reviewWidth > 0 ? 1 : 0)
            Rectangle().fill(p.background).frame(width: max(state.reviewWidth - 1, 0))
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
        .help("Farol \(version) is available. Download it.")
    }
}

/// "± +821 −61": what the session changed, and the way into the review panel.
private struct ReviewButton: View {
    let stat: Diff.Stat
    let active: Bool
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plusminus").foregroundStyle(palette.muted)
                Counts(added: stat.added, removed: stat.removed, palette: palette)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(palette.raised.opacity(hovering || active ? 1 : 0.6), in: Capsule())
            .overlay(Capsule().strokeBorder(palette.line))
        }
        .buttonStyle(.plain)
        .onClickableHover { hovering = $0 }
        .help("Review changes (⌥⌘R)")
    }
}

private struct SessionTitle: View {
    @ObservedObject var session: Session
    var body: some View { Text(session.displayName) }
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
        .help(help)
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
        .help(help)
    }
}
