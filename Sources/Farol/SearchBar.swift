import AppKit
import GhosttyTerminal

/// Find in the scrollback of one pane. Ghostty does the matching, this is only the field and the count.
final class SearchBar: NSView, NSTextFieldDelegate {
    static let size = NSSize(width: 300, height: 30)

    private(set) weak var terminal: TerminalView?
    private let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private var pending: DispatchWorkItem?
    var onClose: (() -> Void)?

    init(for terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.placeholderString = "Find"
        field.delegate = self
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.alignment = .right

        buttons = [
            button("chevron.up", "Previous match (⇧↩)") { [weak self] in self?.terminal?.searchPrevious() },
            button("chevron.down", "Next match (↩)") { [weak self] in self?.terminal?.searchNext() },
            button("xmark", "Close (esc)") { [weak self] in self?.onClose?() },
        ]
        ([field, count] + buttons).forEach(addSubview)

        terminal.onSearchResults = { [weak self] selected, total in self?.show(selected, total) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Field on the left taking the spare width, then the count, then the buttons, all centered vertically.
    override func layout() {
        super.layout()
        let button: CGFloat = 22
        let countWidth: CGFloat = 64
        var x = bounds.width - 6
        for b in buttons.reversed() {
            x -= button
            b.frame = NSRect(x: x, y: (bounds.height - button) / 2, width: button, height: button)
        }
        x -= countWidth + 4
        let textHeight = field.intrinsicContentSize.height
        count.frame = NSRect(x: x, y: (bounds.height - textHeight) / 2, width: countWidth, height: textHeight)
        field.frame = NSRect(x: 10, y: (bounds.height - textHeight) / 2, width: max(x - 14, 40), height: textHeight)
    }

    func begin(with needle: String) {
        if !needle.isEmpty { field.stringValue = needle }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        terminal?.search(field.stringValue)
    }

    func apply(background: NSColor, foreground: NSColor) {
        layer?.backgroundColor = background.mixed(with: foreground, 0.06).cgColor
        layer?.borderColor = background.mixed(with: foreground, 0.16).cgColor
        field.textColor = foreground
        count.textColor = background.mixed(with: foreground, 0.55)
        buttons.forEach { $0.contentTintColor = background.mixed(with: foreground, 0.6) }
    }

    private func show(_ selected: Int?, _ total: Int?) {
        switch (selected, total) {
        case let (selected?, total?) where total > 0: count.stringValue = "\(selected + 1) of \(total)"
        case (_, 0?): count.stringValue = "No matches"
        default: count.stringValue = ""
        }
    }

    // MARK: Typing

    /// Short needles match almost everything, so they wait a moment before searching.
    func controlTextDidChange(_ notification: Notification) {
        pending?.cancel()
        let needle = field.stringValue
        let work = DispatchWorkItem { [weak self] in self?.terminal?.search(needle) }
        pending = work
        let delay: TimeInterval = needle.isEmpty || needle.count >= 3 ? 0 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                terminal?.searchPrevious()
            } else {
                terminal?.searchNext()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> NSButton {
        let button = ActionButton(action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        button.isBordered = false
        button.toolTip = help
        return button
    }
}

/// An NSButton that runs a closure, so the bar needs no @objc methods.
private final class ActionButton: NSButton {
    private let run: () -> Void

    init(action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}
