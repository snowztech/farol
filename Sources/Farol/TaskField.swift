import AppKit
import FarolCore
import SwiftUI

/// The New Task sheet's task. AppKit's text view, since SwiftUI's field can't add a line at the cursor on macOS 14, or take a picture.
/// Return starts the task and Shift-Return adds a line, as in Claude Code.
struct TaskField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    /// Grows with the text from three lines to eight, then scrolls.
    @Binding var height: CGFloat
    /// Each new value puts the cursor in the field, like `focus = .task` would for a SwiftUI one.
    let focusRequest: Int
    let palette: Palette
    let focused: (Bool) -> Void
    let attach: ([URL]) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    static let font = NSFont.systemFont(ofSize: 13)
    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
    static func height(lines: Int) -> CGFloat { CGFloat(lines) * lineHeight }

    func makeNSView(context: Context) -> NSScrollView {
        let view = TaskTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.font = Self.font
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        // A prompt is often code or a command, which curly quotes and long dashes would break.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? TaskTextView else { return }
        context.coordinator.parent = self
        view.events = self
        // Never while an input method composes, which setting the text would cut short.
        if !view.hasMarkedText(), view.string != text { view.string = text }
        view.textColor = NSColor(palette.text)
        view.insertionPointColor = NSColor(palette.text)
        view.placeholder = NSAttributedString(string: placeholder, attributes: [.font: Self.font, .foregroundColor: NSColor(palette.muted)])
        view.needsDisplay = true
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            // On the next turn, once the sheet holding the field is in its window.
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        DispatchQueue.main.async { context.coordinator.fit(view) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TaskField
        var focusRequest = 0

        init(_ parent: TaskField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? TaskTextView else { return }
            parent.text = view.string
            fit(view)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Enter confirms a candidate while an input method is composing. With Shift, it adds a line.
                if textView.hasMarkedText() || NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
                parent.submit()
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.cancel()
            default:
                // Option-Return comes here as insertNewlineIgnoringFieldEditor, and adds a line too.
                return false
            }
            return true
        }

        func fit(_ view: NSTextView) {
            guard let manager = view.layoutManager, let container = view.textContainer else { return }
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container).height
            let fitted = min(max(used, TaskField.height(lines: 3)), TaskField.height(lines: 8)).rounded(.up)
            if abs(fitted - parent.height) > 0.5 { parent.height = fitted }
        }
    }
}

final class TaskTextView: NSTextView {
    var placeholder = NSAttributedString()
    var events: TaskField?

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { events?.focused(true) }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        if gave { events?.focused(false) }
        return gave
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty { placeholder.draw(at: textContainerOrigin) }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    /// Text is pasted as plain text, so a prompt copied from a web page doesn't bring its fonts.
    override func paste(_ sender: Any?) {
        if !attach(from: .general) { pasteAsPlainText(sender) }
    }

    /// A picture dragged from a browser comes as image data, which a plain text view would turn away.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        attach(from: sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    /// Files go by their path, which the agent reads. A picture with no file, like a screenshot, is saved first.
    /// Anything with text stays text, so copying from a page with pictures in it still pastes its words.
    private func attach(from pasteboard: NSPasteboard) -> Bool {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            events?.attach(files)
            return true
        }
        guard pasteboard.string(forType: .string) == nil,
              let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap(Self.png) else { return false }
        if let file = try? Self.inbox.take(UUID(), part: 0, of: 1, data: data) {
            events?.attach([file])
        } else {
            NSSound.beep()
        }
        return true
    }

    private static func png(_ tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// Where the phone's pictures go too, private to you and cleared after a week.
    static let inbox: AttachmentInbox = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return AttachmentInbox(folder: caches.appendingPathComponent("Farol/Attachments"), maxSize: 20 << 20)
    }()
}
