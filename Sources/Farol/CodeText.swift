import AppKit
import FarolCore

/// How Farol shows code, shared by the file pane and the review so they look and behave the same.
enum CodeText {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Plain code: no rich text, no smart quotes, spelling or link helpers.
    static func configure(_ text: NSTextView) {
        text.isRichText = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.font = font
    }

    /// Text, cursor and selection colors, mixed from the terminal theme.
    static func apply(to text: NSTextView, background: NSColor, foreground: NSColor) {
        text.backgroundColor = background
        text.textColor = foreground
        text.insertionPointColor = foreground
        text.typingAttributes = [.font: font, .foregroundColor: foreground]
        text.selectedTextAttributes = [.backgroundColor: background.mixed(with: foreground, 0.22)]
    }

    /// Recolors all of `storage`: plain first, then the tokens. Colors bypass undo because they go straight on the storage.
    static func highlight(_ storage: NSTextStorage, _ language: Syntax.Language?, _ syntax: SyntaxColors?, plain: NSColor) {
        let tokens = language.map { Syntax.tokens(in: storage.string, $0) } ?? []
        color(storage, tokens, syntax, plain: plain)
    }

    static func color(_ storage: NSTextStorage, _ tokens: [Syntax.Token], _ syntax: SyntaxColors?, plain: NSColor) {
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: plain, range: NSRange(location: 0, length: storage.length))
        if let syntax {
            for token in tokens {
                storage.addAttribute(.foregroundColor, value: syntax.color(token.kind), range: token.range)
            }
        }
        storage.endEditing()
    }
}

/// The font of the file editor and the review's diff: the terminal's family and size, so code reads the same everywhere.
/// ⌘+ and ⌘− zoom from there a point at a time, as a terminal does, and ⌘0 goes back. The merge view keeps `CodeText.font`.
@MainActor final class CodeFont: ObservableObject {
    static let shared = CodeFont()
    static let didChange = Notification.Name("CodeFont.didChange")

    @Published private(set) var font = CodeText.font
    /// A diff row: the font's line with the same room around it that 13pt had in its 20pt rows.
    private(set) var rowHeight: CGFloat = 20
    private var family = "", size = 13, zoom = 0

    /// From the settings' font-family and font-size. A new size or family drops the zoom, as it does in a terminal.
    func follow(family: String, size: Int) {
        guard family != self.family || size != self.size else { return }
        (self.family, self.size, zoom) = (family, size, 0)
        update()
    }

    /// ⌘+ (or ⌘=) is 1, ⌘− is -1 and ⌘0 is 0. Nil for any other key.
    nonisolated static func step(for event: NSEvent) -> Int? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock, .shift])
        guard flags == .command else { return nil }
        switch event.charactersIgnoringModifiers {
        case "=", "+": return 1
        case "-": return -1
        case "0": return 0
        default: return nil
        }
    }

    /// One point bigger or smaller, or back to the setting with 0.
    func zoom(_ step: Int) {
        zoom = step == 0 ? 0 : min(max(zoom + step, 6 - size), 48 - size)
        update()
    }

    private func update() {
        let size = CGFloat(size + zoom)
        // A family the Mac doesn't have falls back to the system's monospaced font.
        let new = (family.isEmpty ? nil : NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size))
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        guard new != font else { return }
        let layout = NSLayoutManager()
        rowHeight = (layout.defaultLineHeight(for: new) + 20 - layout.defaultLineHeight(for: CodeText.font)).rounded()
        font = new
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
