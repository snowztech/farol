import AppKit
import FarolCore
import SwiftUI

/// A small editor for the scripts people save from a pane's Run menu.
struct ManageCommandsSheet: View {
    let folder: String
    let top: String?
    let palette: Palette
    let changed: () -> Void
    let close: () -> Void

    @State private var commands: [ProjectCommand]
    @State private var editing: ProjectCommand?
    @State private var name = ""
    @State private var script = ""
    @State private var originalName = ""
    @State private var originalScript = ""
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var confirmingDiscard = false

    private var projectCommands: [ProjectCommand] { commands.filter { !$0.global } }
    private var globalCommands: [ProjectCommand] { commands.filter(\.global) }
    private var hasChanges: Bool { name != originalName || script != originalScript }
    private var deleteTitle: String { "Delete \(editing?.name ?? name)?" }
    private var deleteMessage: String {
        guard let editing else { return "This removes the saved command script. It cannot be undone." }
        let directory = editing.global ? "~/.farol/commands" : "\(editing.folder)/.farol/commands"
        let unsaved = hasChanges ? " Any unsaved edits will be discarded." : ""
        return "This permanently removes \(directory)/\(editing.name).sh. It cannot be undone.\(unsaved)"
    }

    init(folder: String, top: String?, commands: [ProjectCommand], palette: Palette,
         changed: @escaping () -> Void, close: @escaping () -> Void) {
        self.folder = folder
        self.top = top
        self.palette = palette
        self.changed = changed
        self.close = close
        _commands = State(initialValue: commands)
    }

    static func present(in window: NSWindow, folder: String, top: String?, palette: Palette,
                        changed: @escaping () -> Void) {
        guard window.attachedSheet == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let commands = ProjectCommands.saved(in: folder, top: top, globalDirectory: ProjectCommands.globalDirectory)
            DispatchQueue.main.async {
                guard window.attachedSheet == nil else { return }
                let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
                let view = ManageCommandsSheet(folder: folder, top: top, commands: commands, palette: palette, changed: changed,
                                               close: { [weak window, weak sheet] in sheet.map { window?.endSheet($0) } })
                let host = NSHostingController(rootView: view)
                host.sizingOptions = [.preferredContentSize]
                sheet.contentViewController = host
                window.beginSheet(sheet)
            }
        }
    }

    var body: some View {
        Group {
            if let editing {
                editor(editing)
            } else {
                list
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(palette.text)
        .frame(width: 460)
        .background(palette.background)
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Command", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { returnToList() }
            Button("Continue Editing", role: .cancel) {}
        } message: {
            Text("Your changes to this command have not been saved.")
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Saved commands").font(.system(size: 15, weight: .semibold))
                Text("Edit or remove a command saved for this project or all projects.")
                    .foregroundStyle(palette.muted)
            }
            .padding(20)

            Rectangle().fill(palette.line).frame(height: 1)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(palette.removed)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
            if commands.isEmpty {
                Text("No saved commands here yet.")
                    .foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .padding(.horizontal, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if !projectCommands.isEmpty {
                            section("This project", commands: projectCommands)
                        }
                        if !globalCommands.isEmpty {
                            if !projectCommands.isEmpty { Rectangle().fill(palette.line).frame(height: 1).padding(.horizontal, 20) }
                            section("All projects", commands: globalCommands)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            Rectangle().fill(palette.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Close", action: close)
                    .buttonStyle(SheetButton(palette: palette, primary: false))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private func section(_ title: String, commands: [ProjectCommand]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(palette.muted)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 4)
            ForEach(commands, id: \.self) { command in
                Button { beginEditing(command) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(command.name).foregroundStyle(palette.text)
                            if !command.global {
                                Text(scope(for: command)).font(.system(size: 11)).foregroundStyle(palette.muted)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.muted)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                if command != commands.last { Rectangle().fill(palette.line).frame(height: 1).padding(.leading, 20) }
            }
        }
    }

    private func editor(_ command: ProjectCommand) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Edit command").font(.system(size: 15, weight: .semibold))
                Text(scope(for: command)).font(.system(size: 12)).foregroundStyle(palette.muted)
            }
            .padding(20)

            Rectangle().fill(palette.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Name").foregroundStyle(palette.muted)
                    TextField("Preview site", text: $name)
                        .textFieldStyle(.plain)
                        .sheetField(palette, focused: false)
                        .onChange(of: name) { _, _ in error = nil }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Command").foregroundStyle(palette.muted)
                    TextField("npm run dev", text: $script, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(3...8)
                        .sheetField(palette, focused: false)
                        .onChange(of: script) { _, _ in error = nil }
                }
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(palette.removed)
                }
            }
            .padding(20)

            Rectangle().fill(palette.line).frame(height: 1)
            HStack {
                Button("Back") { backToList() }
                    .buttonStyle(SheetButton(palette: palette, primary: false))
                    .keyboardShortcut(.cancelAction)
                Button {
                    confirmingDelete = true
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.removed)
                Spacer()
                Button("Save Changes") { save(command) }
                    .buttonStyle(SheetButton(palette: palette, primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || !hasChanges)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private func scope(for command: ProjectCommand) -> String {
        if command.global { return "All projects" }
        guard let top, command.folder != top, command.folder.hasPrefix(top + "/") else { return ".farol/commands" }
        return String(command.folder.dropFirst(top.count + 1)) + "/.farol/commands"
    }

    private func beginEditing(_ command: ProjectCommand) {
        do {
            name = command.name
            script = try ProjectCommands.script(for: command)
            originalName = name
            originalScript = script
            error = nil
            editing = command
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ command: ProjectCommand) {
        do {
            try ProjectCommands.update(command, name: name, script: script)
            refresh()
            changed()
            editing = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() {
        guard let editing else { return }
        do {
            try ProjectCommands.delete(editing)
            refresh()
            changed()
            self.editing = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func backToList() {
        if hasChanges {
            confirmingDiscard = true
        } else {
            returnToList()
        }
    }

    private func returnToList() {
        editing = nil
        error = nil
        confirmingDiscard = false
    }

    private func refresh() {
        commands = ProjectCommands.saved(in: folder, top: top, globalDirectory: ProjectCommands.globalDirectory)
    }
}
