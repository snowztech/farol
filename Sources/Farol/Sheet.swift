import SwiftUI

// The pieces Farol's own sheets are built from, so they look like one app in any terminal theme.

/// The sheet's own buttons, in the theme's colors.
/// The system ones take the macOS accent color, blue by default, which belongs to no terminal theme.
struct SheetButton: ButtonStyle {
    let palette: Palette
    let primary: Bool

    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(primary ? palette.background : palette.text)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(primary ? palette.text : palette.raised))
            .opacity(!enabled ? 0.35 : configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
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

extension View {
    /// The box around a plain text field, with a brighter edge while you type in it.
    func sheetField(_ palette: Palette, focused: Bool) -> some View {
        tint(palette.text)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? palette.muted : palette.line))
    }
}
