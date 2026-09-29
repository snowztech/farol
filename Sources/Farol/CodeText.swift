import AppKit
import FarolCore

/// How Farol shows code, shared by the file pane and the review so they look and behave the same.
enum CodeText {
    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

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
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: plain, range: NSRange(location: 0, length: storage.length))
        if let language, let syntax {
            for token in Syntax.tokens(in: storage.string, language) {
                storage.addAttribute(.foregroundColor, value: syntax.color(token.kind), range: token.range)
            }
        }
        storage.endEditing()
    }
}
