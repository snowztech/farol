import AppKit
import SwiftUI

struct AddCommandSheet: View {
    private enum Field: Hashable { case name, command }

    let root: String
    let palette: Palette
    let save: (String, String, Bool) throws -> Void
    let close: () -> Void

    @State private var name = ""
    @State private var command = ""
    @State private var global = false
    @State private var error: String?
    @FocusState private var focus: Field?

    static func present(in window: NSWindow, root: String, palette: Palette,
                        save: @escaping (String, String, Bool) throws -> Void) {
        guard window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        let view = AddCommandSheet(root: root, palette: palette, save: save,
                                   close: { [weak window, weak sheet] in sheet.map { window?.endSheet($0) } })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add command").font(.system(size: 15, weight: .semibold))
                    Text("Save a command to run from a pane or ⌘P.")
                        .foregroundStyle(p.muted)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").foregroundStyle(p.muted)
                    TextField("Preview site", text: $name)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .name)
                        .sheetField(p, focused: focus == .name)
                        .onChange(of: name) { _, _ in error = nil }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command").foregroundStyle(p.muted)
                    TextField("npm run dev", text: $command)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($focus, equals: .command)
                        .sheetField(p, focused: focus == .command)
                        .onChange(of: command) { _, _ in error = nil }
                    Text("Edit the saved script later for multiple lines.")
                        .font(.system(size: 12))
                        .foregroundStyle(p.muted)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Save for").foregroundStyle(p.muted)
                    HStack(spacing: 8) {
                        SheetOption(title: "This project", selected: !global, palette: p) {
                            global = false
                            error = nil
                        }
                        SheetOption(title: "All projects", selected: global, palette: p) {
                            global = true
                            error = nil
                        }
                    }
                    Text(global ? "~/.farol/commands/ · runs in the active pane's folder"
                         : "\((root as NSString).abbreviatingWithTildeInPath)/.farol/commands/ · runs from this checkout")
                        .font(.system(size: 12))
                        .foregroundStyle(p.muted)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(p.removed)
                }
            }
            .padding(20)
            Rectangle().fill(p.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(SheetButton(palette: p, primary: false))
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    do {
                        try save(name, command, global)
                        close()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .buttonStyle(SheetButton(palette: p, primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .frame(width: 460)
        .background(p.background)
        .ignoresSafeArea()
        .onAppear { focus = .name }
    }
}
