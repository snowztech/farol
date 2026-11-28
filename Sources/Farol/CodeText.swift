import AppKit
import FarolCore

/// How Farol shows code, shared by the file pane and the review so they look and behave the same.
enum CodeText {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    /// The file editor's font: the terminal's family and size, so code reads the same in both.
    /// Diffs and the merge view keep `font`, since their rows have a fixed height.
    @MainActor static private(set) var editorFont = font
    static let editorFontDidChange = Notification.Name("CodeText.editorFontDidChange")

    /// From the settings' font-family and font-size. A family the Mac doesn't have falls back to the system's monospaced font.
    @MainActor static func follow(family: String, size: Int) {
        let size = CGFloat(size)
        let new = (family.isEmpty ? nil : NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size))
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        guard new != editorFont else { return }
        editorFont = new
        NotificationCenter.default.post(name: editorFontDidChange, object: nil)
    }

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
