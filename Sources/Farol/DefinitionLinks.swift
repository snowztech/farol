import AppKit
import FarolCore

/// Go to definition in a file's text: with ⌘ held, a name the project declares is underlined, and a click goes to it.
/// The view only passes on where the mouse is and where it clicked.
@MainActor
final class DefinitionLinks {
    /// The file the text is, which says what a name is and where to look for it.
    var path = "" {
        didSet {
            reset()
            // Ready before ⌘ is first held, so the first name under the mouse lights at once.
            DefinitionIndexes.index(for: path) { _ in }
        }
    }
    var open: ((String, Int) -> Void)?
    var palette: () -> Palette? = { nil }
    /// Where the lit name is drawn, for the pointer to be a hand over it.
    var onLink: ((NSRect?) -> Void)?

    private unowned let text: NSTextView
    /// Underlined as Xcode does, in its own color, which reads in every theme and leaves color to agent status.
    private var lit: NSRange?
    /// The name under the mouse, lit only once it is known to lead somewhere.
    private var hovered: NSRange?
    /// Answers per name, and whether it is a member, while ⌘ is held, so the click is instant. Dropped when ⌘ is let go or the text changes.
    private var lookups: [String: Lookup] = [:]

    private struct Lookup {
        let folder: String
        let matches: [FileSearch.Match]

        /// Nothing from the declaration itself, which is already where it would lead.
        func answers(from file: String, line: Int) -> [FileSearch.Match] {
            matches.contains { folder + "/" + $0.path == file && $0.line == line } ? [] : matches
        }
    }

    init(text: NSTextView) {
        self.text = text
    }

    /// The character under the mouse while ⌘ is held, or nil once it isn't.
    func hover(at index: Int?) {
        guard let index else { return reset() }
        let range = wordRange(at: index)
        guard range != hovered else { return }
        hovered = range
        underline(nil)
        guard let range else { return }
        let (file, line) = (path, lineNumber(of: index))
        let word = (text.string as NSString).substring(with: range)
        lookUp(word, member: Definitions.isMember(in: text.string, at: range)) { [weak self] lookup in
            guard let self, hovered == range, !lookup.answers(from: file, line: line).isEmpty else { return }
            underline(range)
        }
    }

    /// To where the project declares the name, or a choice when it is declared in several places.
    func click(at index: Int) {
        guard let range = wordRange(at: index) else { return NSSound.beep() }
        // The cursor goes where you clicked, so going back lands on this spot and not on wherever it was.
        text.setSelectedRange(NSRange(location: index, length: 0))
        let word = (text.string as NSString).substring(with: range)
        let (file, line) = (path, lineNumber(of: index))
        let member = Definitions.isMember(in: text.string, at: range)
        lookUp(word, member: member) { [weak self] lookup in
            guard let self, path == file else { return }
            let found = lookup.answers(from: file, line: line)
            guard !found.isEmpty else { return NSSound.beep() }
            if let match = Definitions.best(found, from: file, in: lookup.folder, line: line, member: member) {
                return open?(lookup.folder + "/" + match.path, match.line) ?? ()
            }
            guard let palette = palette() else { return }
            DefinitionPicker.show(found, of: word, palette: palette, below: rect(of: range), in: text) { [weak self] match in
                self?.open?(lookup.folder + "/" + match.path, match.line)
            }
        }
    }

    /// An edit can add or move a local, and moves the text under the underline.
    func textChanged() {
        reset()
    }

    private func reset() {
        lookups = [:]
        hovered = nil
        underline(nil)
    }

    private func lookUp(_ word: String, member: Bool, then done: @escaping (Lookup) -> Void) {
        let key = member ? "." + word : word
        if let known = lookups[key] { return done(known) }
        let file = path
        DefinitionIndexes.index(for: file) { [weak self] index in
            guard let self, path == file else { return }
            let lookup = Lookup(folder: index.folder, matches: index.find(word, from: file, text: text.string, member: member))
            lookups[key] = lookup
            done(lookup)
        }
    }

    private func wordRange(at index: Int) -> NSRange? {
        // Vue templates write a component as <my-button>.
        Definitions.wordRange(in: text.string, at: index, hyphens: path.hasSuffix(".vue"))
    }

    private func underline(_ range: NSRange?) {
        guard range != lit, let layout = text.layoutManager else { return }
        let length = (text.string as NSString).length
        if let old = lit {
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSIntersectionRange(old, NSRange(location: 0, length: length)))
        }
        lit = range
        guard let range, NSMaxRange(range) <= length else { return onLink?(nil) ?? () }
        layout.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: range)
        onLink?(rect(of: range))
    }

    /// Where characters are drawn, in the text view's own coordinates.
    private func rect(of range: NSRange) -> NSRect {
        guard let layout = text.layoutManager, let container = text.textContainer else { return .zero }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    }

    /// The line a character is on, counting from 1.
    private func lineNumber(of index: Int) -> Int {
        let string = text.string as NSString
        let end = min(index, string.length)
        var line = 1
        var position = 0
        while position < end {
            let found = string.range(of: "\n", range: NSRange(location: position, length: end - position))
            guard found.location != NSNotFound else { break }
            line += 1
            position = NSMaxRange(found)
        }
        return line
    }
}
