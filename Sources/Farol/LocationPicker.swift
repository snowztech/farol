import AppKit
import FarolCore
import SwiftUI

/// Places in the code to pick from: a name's definitions when there are several, or the references to it.
/// Rows shaped like the session switcher's, so it reads as Farol's.
struct LocationPicker: View {
    /// One place, with its line as the file has it, from 1.
    struct Place: Hashable {
        let path: String
        let line: Int
        let text: String
    }

    /// Like "3 references to", which the name follows.
    let title: String
    let word: String
    let matches: [Place]
    let palette: Palette
    let choose: (Place) -> Void

    /// Under the arrows or the mouse. Return opens it.
    @State private var active = 0
    @FocusState private var focused: Bool

    private static let rowHeight: CGFloat = 30

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            Text("\(title) \(Text(word).font(.system(size: 11, design: .monospaced)).foregroundColor(p.text))")
                .font(.system(size: 11))
                .foregroundStyle(p.muted)
                .padding(.horizontal, 15)
                .padding(.top, 10)
                .padding(.bottom, 2)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                            row(match, lit: index == active, palette: p)
                                .onClickableHover { if $0 { active = index } }
                                .id(index)
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(CGFloat(matches.count) * (Self.rowHeight + 1) + 12, 320))
                .onChange(of: active) { _, row in scroll.scrollTo(row) }
            }
        }
        .frame(width: 480)
        .foregroundStyle(p.text)
        .background(p.boxed ? p.surface : p.background)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.return) {
            choose(matches[active])
            return .handled
        }
        .onAppear { focused = true }
    }

    private func row(_ match: Place, lit: Bool, palette p: Palette) -> some View {
        Button { choose(match) } label: {
            HStack(spacing: 9) {
                FileIcon(path: match.path).font(.system(size: 11)).foregroundStyle(p.muted).frame(width: 15)
                Text(match.text)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                Text("\((match.path as NSString).lastPathComponent):\(match.line)")
                    .font(.system(size: 11))
                    .foregroundStyle(p.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 9)
            .frame(height: Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lit ? p.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietPress())
        .help("\((match.path as NSString).abbreviatingWithTildeInPath):\(match.line)")
    }

    private func move(_ step: Int) -> KeyPress.Result {
        active = (active + step + matches.count) % matches.count
        return .handled
    }

    /// Opens under the name that was clicked, or above it near the bottom of the screen.
    /// A panel of its own rather than a popover, whose arrow is drawn by macOS in its own colors and whose anchor drifts inside a scroll view.
    @MainActor
    static func show(_ matches: [Place], title: String, word: String, palette: Palette, below rect: NSRect, in view: NSView,
                     choose: @escaping (Place) -> Void) {
        guard let window = view.window else { return }
        let anchor = window.convertToScreen(view.convert(rect, to: nil))
        FloatingPanel.show(palette: palette, over: window, place: { size, screen in
            var origin = NSPoint(x: anchor.minX - 15, y: anchor.minY - 4 - size.height)
            if origin.y < screen.minY { origin.y = anchor.maxY + 4 }
            return origin
        }) { dismiss in
            LocationPicker(title: title, word: word, matches: matches, palette: palette) { match in
                dismiss()
                choose(match)
            }
        }
    }
}
