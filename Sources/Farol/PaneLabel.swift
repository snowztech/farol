import AppKit

/// The name tag in a pane's top right corner. Double-click to rename, and an empty name removes it.
final class PaneLabel: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    private var before = ""
    /// Called with the new name when editing ends, or nil to remove the label.
    var onCommit: ((String?) -> Void)?

    var name: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11, weight: .medium)
        field.placeholderString = "Name"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.isEditable = false
        field.isSelectable = false
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(background: NSColor, foreground: NSColor, focused: Bool) {
        layer?.backgroundColor = background.mixed(with: foreground, 0.06).cgColor
        layer?.borderColor = background.mixed(with: foreground, focused ? 0.3 : 0.14).cgColor
        field.textColor = focused ? foreground : background.mixed(with: foreground, 0.6)
    }

    /// Wide enough for the name, or for typing one. The cell's own size includes the text field's padding.
    var fittingWidth: CGFloat {
        let width = field.cell?.cellSize.width ?? 0
        return min(max(width, isEditing ? 80 : 0) + 16, 240)
    }

    private var isEditing: Bool { field.isEditable }

    func beginEditing() {
        before = name
        field.isEditable = true
        field.isSelectable = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        superview?.needsLayout = true
    }

    override func layout() {
        super.layout()
        field.frame = bounds.insetBy(dx: 8, dy: 2)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { beginEditing() }
    }

    func controlTextDidChange(_ obj: Notification) {
        superview?.needsLayout = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)) else { return false }
        name = before
        window?.makeFirstResponder(nil)
        return true
    }

    /// Return, Escape and clicking elsewhere all end up here.
    func controlTextDidEndEditing(_ obj: Notification) {
        field.isEditable = false
        field.isSelectable = false
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        onCommit?(trimmed.isEmpty ? nil : trimmed)
    }
}
