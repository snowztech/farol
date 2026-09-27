import AppKit
import GhosttyKit

/// Lets macOS input methods work in the terminal: dead keys, accents, Japanese, Chinese and Korean input.
extension TerminalView: NSTextInputClient {
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.string(from: string)
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else {
            sendText(text)
        }
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = Self.string(from: string)
        // During a key press, keyDown syncs once the input system is done.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    public func unmarkText() {
        guard !markedText.isEmpty else { return }
        markedText = ""
        syncPreedit()
    }

    public func hasMarkedText() -> Bool { !markedText.isEmpty }

    public func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (markedText as NSString).length)
    }

    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Places the input method's candidate window at the terminal cursor.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let rect = NSRect(x: x, y: frame.height - y, width: 0, height: height)
        return window.convertToScreen(convert(rect, to: nil))
    }

    private static func string(from value: Any) -> String {
        (value as? NSAttributedString)?.string ?? (value as? String) ?? ""
    }
}
