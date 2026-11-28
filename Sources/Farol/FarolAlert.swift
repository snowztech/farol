import AppKit
import SwiftUI

/// A question or a note, drawn like Farol's other sheets rather than as the system's alert. It answers like NSAlert:
/// the first button is the default on the right, Return picks it, Esc picks Cancel, and the completion gets `.alertFirstButtonReturn` on.
/// Used where NSAlert was, including code the compiler can't see runs on the main thread, which it checks.
final class FarolAlert {
    var messageText = ""
    var informativeText = ""
    /// A text field under the message, for a name to type, and what it holds when the sheet opens.
    var field: (placeholder: String, value: String)?
    /// A checkbox under the message, which starts off.
    var checkbox: String?
    /// What the field held and whether the box was ticked, read in the completion.
    private(set) var fieldValue = ""
    private(set) var checked = false
    private var buttons: [String] = []

    /// The theme's colors, kept current by the window, so an alert raised outside a view looks like the rest.
    @MainActor static var palette: Palette?

    init() {}

    /// For an error, with its description as the title, as NSAlert(error:) does.
    convenience init(error: Error) {
        self.init()
        messageText = error.localizedDescription
    }

    func addButton(withTitle title: String) {
        buttons.append(title)
    }

    func beginSheetModal(for window: NSWindow, completionHandler done: ((NSApplication.ModalResponse) -> Void)? = nil) {
        MainActor.assumeIsolated { present(in: window, done) }
    }

    @MainActor private func present(in window: NSWindow, _ done: ((NSApplication.ModalResponse) -> Void)?) {
        guard let palette = Self.palette else { return systemAlert().beginSheetModal(for: window, completionHandler: done) }
        let titles = buttons.isEmpty ? ["OK"] : buttons
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        let view = AlertSheet(title: messageText, message: informativeText, buttons: titles, field: field, checkbox: checkbox,
                              palette: palette) { [weak window, weak sheet] index, value, ticked in
            self.fieldValue = value
            self.checked = ticked
            if let sheet { window?.endSheet(sheet) }
            // After the sheet is gone, so a sheet that follows can open.
            DispatchQueue.main.async { done?(NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)) }
        }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }

    /// On the key window, or as the system's own when no window is there to hold a sheet.
    func show(_ done: ((NSApplication.ModalResponse) -> Void)? = nil) {
        MainActor.assumeIsolated {
            if let window = NSApp.keyWindow { return present(in: window, done) }
            let response = systemAlert().runModal()
            done?(response)
        }
    }

    /// The same question as the system draws it, for before the theme is known.
    @MainActor private func systemAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert
    }
}

private struct AlertSheet: View {
    let title: String
    let message: String
    let buttons: [String]
    let field: (placeholder: String, value: String)?
    let checkbox: String?
    let palette: Palette
    let choose: (Int, String, Bool) -> Void

    @State private var value = ""
    @State private var ticked = false
    @FocusState private var typing: Bool

    /// Esc means Cancel, or the last choice when there's no Cancel, like Later.
    private var cancel: Int? {
        buttons.firstIndex(of: "Cancel") ?? (buttons.count > 1 ? buttons.count - 1 : nil)
    }

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: title, palette: p) {
                if !message.isEmpty {
                    // A long one, like a list of config errors, scrolls rather than pushing the buttons off screen.
                    ScrollView {
                        Text(message)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 260)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let field {
                TextField(field.placeholder, text: $value)
                    .textFieldStyle(.plain)
                    .focused($typing)
                    .onSubmit { choose(0, value, ticked) }
                    .sheetField(p, focused: typing)
            }
            if let checkbox {
                Toggle(checkbox, isOn: $ticked).toggleStyle(.checkbox)
            }
            HStack(spacing: 8) {
                Spacer()
                // The first button is the default and sits on the right, as macOS puts it.
                ForEach(buttons.indices.reversed(), id: \.self) { index in
                    Button(buttons[index]) { choose(index, value, ticked) }
                        .buttonStyle(SheetButton(palette: p, primary: index == 0))
                        .keyboardShortcut(index == 0 ? .defaultAction : index == cancel ? .cancelAction : nil)
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .padding(24)
        .frame(width: 420, alignment: .leading)
        .background(p.background)
        .onAppear {
            value = field?.value ?? ""
            typing = field != nil
        }
    }
}
