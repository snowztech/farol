import AppKit
import FarolCore

/// Go to definition and find references in a file's text, answered by the language server, only when they are turned on in Settings.
/// With ⌘ held, a name the server can place is underlined. A click goes to it, or on the name's own declaration lists where it's used.
/// The view only passes on where the mouse is and where it clicked.
@MainActor
final class DefinitionLinks {
    /// The file the text is. Changing it tells the server the old one closed.
    var path = "" {
        didSet {
            if !oldValue.isEmpty, oldValue != path { LanguageServers.shared.close(oldValue) }
            reset()
        }
    }
    var open: ((String, Int) -> Void)?
    var palette: () -> Palette? = { nil }
    /// Where the lit name is drawn, for the pointer to be a hand over it.
    var onLink: ((NSRect?) -> Void)?

    private unowned let text: NSTextView
    /// Underlined as Xcode does, in its own color, which reads in every theme and leaves color to agent status.
    private var lit: NSRange?
    /// The name under the mouse, lit only once the server says it leads somewhere.
    private var hovered: NSRange?
    /// The server's answers per name while ⌘ is held, so the click is instant. Dropped when ⌘ is let go or the text changes.
    private var answers: [NSRange: [LSP.Location]] = [:]

    init(text: NSTextView) {
        self.text = text
    }

    /// The character under the mouse while ⌘ is held, or nil once it isn't.
    func hover(at index: Int?) {
        guard LanguageServers.shared.isEnabled(for: path) else { return }
        guard let index else { return reset() }
        let range = wordRange(at: index)
        guard range != hovered else { return }
        hovered = range
        underline(nil)
        guard let range else { return }
        definitions(of: range) { [weak self] found in
            guard let self, hovered == range, !found.isEmpty else { return }
            underline(range)
        }
    }

    func click(at index: Int) {
        guard LanguageServers.shared.isEnabled(for: path) else { return }
        guard let range = wordRange(at: index) else { return NSSound.beep() }
        // The cursor goes where you clicked, so the file keeps your place.
        text.setSelectedRange(NSRange(location: index, length: 0))
        let word = (text.string as NSString).substring(with: range)
        definitions(of: range) { [weak self] found in
            guard let self else { return }
            guard !found.isEmpty else { return NSSound.beep() }
            // On the name's own declaration there is nowhere to go, so the places that use it are what you want.
            if found.allSatisfy(isHere(range)) { return references(of: range, word: word) }
            if found.count == 1 { return go(to: found[0]) }
            pick(found, title: "\(found.count) definitions of", word: word, below: range)
        }
    }

    /// An edit moves the text under the underline and can change what names mean.
    func textChanged() {
        reset()
    }

    /// The file came to the front: its server starts loading the project now, so a ⌘-click a moment later is answered at once.
    /// The text goes along, which also opens the file in the server.
    func warm() {
        guard LanguageServers.shared.isEnabled(for: path), LanguageServers.shared.existing(for: path) == nil else { return }
        let (file, content) = (path, text.string)
        LanguageServers.shared.server(for: file) { $0?.sync(file, text: content) }
    }

    /// The file's tab closed.
    func closed() {
        LanguageServers.shared.close(path)
    }

    // MARK: Asking the server

    private func definitions(of range: NSRange, then done: @escaping ([LSP.Location]) -> Void) {
        if let known = answers[range] { return done(known) }
        ask("textDocument/definition", at: range, extra: [:]) { [weak self] found in
            self?.answers[range] = found
            done(found)
        }
    }

    private func references(of range: NSRange, word: String) {
        ask("textDocument/references", at: range, extra: ["context": ["includeDeclaration": false]]) { [weak self] found in
            guard let self else { return }
            guard !found.isEmpty else { return NSSound.beep() }
            if found.count == 1 { return go(to: found[0]) }
            pick(found, title: "\(found.count) references to", word: word, below: range)
        }
    }

    /// Starts the file's server if it isn't running, sends it the text as it is now, then asks.
    private func ask(_ method: String, at range: NSRange, extra: [String: Any], then done: @escaping ([LSP.Location]) -> Void) {
        let (file, content) = (path, text.string)
        let position = LSP.position(of: range.location, in: content)
        LanguageServers.shared.server(for: file) { server in
            guard let server else { return done([]) }
            server.sync(file, text: content)
            server.request(method, LSP.place(file, position).merging(extra) { $1 }) { [weak self] result in
                guard let self, path == file else { return }
                done(LSP.locations(from: result))
            }
        }
    }

    // MARK: Going there

    private func go(to location: LSP.Location) {
        open?(location.path, location.position.line + 1)
    }

    private func pick(_ found: [LSP.Location], title: String, word: String, below range: NSRange) {
        guard let palette = palette() else { return }
        var files: [String: [Substring]] = [:]
        let places = found.map { location in
            // The open file's own text, which may hold edits the disk doesn't have yet.
            let lines = files[location.path] ?? {
                let content = location.path == path ? text.string : ((try? String(contentsOfFile: location.path, encoding: .utf8)) ?? "")
                let split = content.split(separator: "\n", omittingEmptySubsequences: false)
                files[location.path] = split
                return split
            }()
            let line = lines.indices.contains(location.position.line) ? lines[location.position.line] : ""
            return LocationPicker.Place(path: location.path, line: location.position.line + 1,
                                        text: line.trimmingCharacters(in: .whitespaces))
        }
        LocationPicker.show(places, title: title, word: word, palette: palette, below: rect(of: range), in: text) { [weak self] place in
            self?.open?(place.path, place.line)
        }
    }

    private func isHere(_ range: NSRange) -> (LSP.Location) -> Bool {
        let start = LSP.position(of: range.location, in: text.string)
        return { [path] location in
            location.path == path && location.position.line == start.line
                && (start.character...(start.character + range.length)).contains(location.position.character)
        }
    }

    // MARK: The underline

    private func reset() {
        answers = [:]
        hovered = nil
        underline(nil)
    }

    /// A name: letters, digits, `_` and `$`, which every language the servers cover writes names with.
    private func wordRange(at index: Int) -> NSRange? {
        let string = text.string as NSString
        func part(_ at: Int) -> Bool {
            guard at >= 0, at < string.length, let scalar = Unicode.Scalar(string.character(at: at)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
        }
        // A click just after a name's last letter, as at the end of a line, still means that name.
        var start = min(index, string.length)
        if !part(start) { start -= 1 }
        guard part(start) else { return nil }
        var end = start
        while part(start - 1) { start -= 1 }
        while part(end + 1) { end += 1 }
        guard let first = Unicode.Scalar(string.character(at: start)), !CharacterSet.decimalDigits.contains(first) else { return nil }
        return NSRange(location: start, length: end - start + 1)
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
}
