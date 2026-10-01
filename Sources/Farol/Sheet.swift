import SwiftUI

// The pieces Farol's own sheets are built from, so they look like one app in any terminal theme.

/// The sheet's own buttons, in the theme's colors.
/// The system ones take the macOS accent color, blue by default, which belongs to no terminal theme.
struct SheetButton: ButtonStyle {
    let palette: Palette
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, palette: palette, primary: primary)
    }

    /// A style can't keep state of its own, and the hover needs some.
    private struct Face: View {
        let configuration: Configuration
        let palette: Palette
        let primary: Bool

        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(primary ? palette.background : palette.text)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(primary ? palette.text : palette.raised))
                // A wash of the label's color, so both buttons shift the same way under the mouse.
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .fill((primary ? palette.background : palette.text).opacity(hovering && enabled ? 0.12 : 0)))
                .opacity(!enabled ? 0.35 : configuration.isPressed ? 0.8 : 1)
                .contentShape(Rectangle())
                .onClickableHover { hovering = $0 }
        }
    }
}

/// One choice among a few, with a radio mark.
struct SheetOption: View {
    let title: String
    let selected: Bool
    let palette: Palette
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? palette.text : palette.muted)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? palette.raised : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A field that opens a list of choices under it, drawn like the text fields around it.
/// The system's menu takes its own colors and grows as wide as its longest title.
struct SheetSelect<Label: View, Choices: View>: View {
    let palette: Palette
    @Binding var open: Bool
    @ViewBuilder let label: Label
    @ViewBuilder let choices: Choices

    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                label
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheetField(palette, focused: open || hovering)
        .onClickableHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            choices
                .font(.system(size: 13))
                .foregroundStyle(palette.text)
                .background(palette.background)
        }
    }
}

/// One row in a select's list, lit under the mouse.
struct SheetChoice<Label: View>: View {
    let palette: Palette
    let choose: () -> Void
    @ViewBuilder let label: Label

    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                label
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? palette.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onClickableHover { hovering = $0 }
    }
}

extension View {
    /// The box around a plain text field, with a brighter edge while you type in it.
    func sheetField(_ palette: Palette, focused: Bool) -> some View {
        tint(palette.text)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? palette.muted : palette.line))
    }
}
