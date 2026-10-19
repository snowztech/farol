import AppKit
import FarolCore
import GhosttyTerminal
import SwiftUI

/// Named commands kept per folder, run from a pane's context menu.
extension PaneContainer {
    func addCommandsMenu(to menu: NSMenu, for terminal: TerminalView) {
        menu.addItem(withTitle: "Commands", action: nil, keyEquivalent: "").submenu = commandsMenu(for: terminal)
    }

    /// The focused pane's commands, numbered, under its top left corner. A digit runs one at once.
    /// With none saved yet, it asks for the first one.
    func showCommands(palette: Palette) {
        let terminal = focused
        let folder = terminal.workingDirectory ?? NSHomeDirectory()
        let saved = Array(SavedCommands().available(in: folder).prefix(9))
        guard !saved.isEmpty else { return editCommand(nil, folder: folder) }
        let anchor = NSRect(x: terminal.frame.minX + 12, y: terminal.frame.minY + 12, width: 1, height: 1)
        CommandPicker.shared.show(saved, folder: folder, busy: terminal.runsProgram, palette: palette, at: anchor, in: self) { [weak terminal] command in
            guard let terminal else { return }
            terminal.window?.makeFirstResponder(terminal)
            run(command, in: terminal)
        }
    }

    private func commandsMenu(for terminal: TerminalView) -> NSMenu {
        let folder = terminal.workingDirectory ?? NSHomeDirectory()
        let saved = SavedCommands().available(in: folder)
        let submenu = NSMenu()
        // Typed at the shell's prompt, so a program in front, like vim or an agent, would get it instead.
        let busy = terminal.runsProgram
        for command in saved {
            let item = ActionMenuItem(title: command.name) { [weak terminal] in
                if let terminal { run(command, in: terminal) }
            }
            item.toolTip = busy ? "A program is running in this pane" : command.command
            item.isEnabled = !busy
            submenu.addItem(item)
        }
        if !saved.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(ActionMenuItem(title: "New Command…") { [weak self] in self?.editCommand(nil, folder: folder) })
        if !saved.isEmpty {
            let edit = NSMenu()
            saved.forEach { command in edit.addItem(ActionMenuItem(title: command.name) { [weak self] in self?.editCommand(command, folder: folder) }) }
            submenu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        }
        submenu.autoenablesItems = false
        return submenu
    }

    /// A new command is kept for the pane's folder. An edited one stays with the folder it was saved for.
    private func editCommand(_ old: SavedCommand?, folder: String) {
        let alert = NSAlert()
        alert.messageText = old == nil ? "New Command" : "Edit Command"
        let shown = ((old?.folder ?? folder) as NSString).abbreviatingWithTildeInPath
        alert.informativeText = "Available in \(shown) and its subfolders."
        let name = NSTextField(string: old?.name ?? "")
        name.placeholderString = "Name"
        let command = NSTextField(string: old?.command ?? "")
        command.placeholderString = "Command, like make test"
        let fields = NSStackView(views: [name, command])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        name.widthAnchor.constraint(equalToConstant: 300).isActive = true
        command.widthAnchor.constraint(equalToConstant: 300).isActive = true
        alert.accessoryView = fields
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if old != nil { alert.addButton(withTitle: "Delete").hasDestructiveAction = true }
        alert.window.initialFirstResponder = name
        let done = { (response: NSApplication.ModalResponse) in
            let store = SavedCommands()
            switch response {
            case .alertFirstButtonReturn:
                store.save(SavedCommand(name: name.stringValue, command: command.stringValue, folder: old?.folder ?? folder), replacing: old)
            case .alertThirdButtonReturn:
                if let old { store.remove(old) }
            default: break
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }
}

private func run(_ command: SavedCommand, in terminal: TerminalView) {
    terminal.pasteText(command.command)
    terminal.press(.enter)
}

/// A numbered list of commands that runs one on its digit.
/// A popped up NSMenu keeps the keys to itself and only selects by title, so this reads them before the terminal does.
private final class CommandPicker: NSObject, NSPopoverDelegate {
    static let shared = CommandPicker()

    private var popover: NSPopover?
    private var keys: Any?
    private var model: CommandList.Model?
    private var run: ((SavedCommand) -> Void)?

    func show(_ commands: [SavedCommand], folder: String, busy: Bool, palette: Palette, at rect: NSRect, in view: NSView,
              run: @escaping (SavedCommand) -> Void) {
        popover?.close()
        let model = CommandList.Model(commands: commands)
        let list = CommandList(model: model, folder: (folder as NSString).abbreviatingWithTildeInPath, busy: busy, palette: palette) {
            [weak self] in self?.pick($0)
        }
        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: list)
        popover.behavior = .transient
        popover.delegate = self
        self.popover = popover
        self.model = model
        self.run = busy ? nil : run
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Not `self?.key(event) ?? event`, which would hand on the very keys key(_:) keeps.
            guard let self else { return event }
            return self.key(event)
        }
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    private func key(_ event: NSEvent) -> NSEvent? {
        guard let model else { return event }
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if plain, let digit = Self.digit(event.keyCode) {
            if model.commands.indices.contains(digit - 1) { pick(digit - 1) }
            return nil
        }
        switch event.keyCode {
        case 125: model.move(1)
        case 126: model.move(-1)
        case 36, 76: pick(model.lit)
        case 53: popover?.close()
        default:
            // Any other key goes on to the terminal.
            popover?.close()
            return event
        }
        return nil
    }

    /// By key rather than by character, so the top row works on any layout, like AZERTY where it types & without Shift.
    private static func digit(_ keyCode: UInt16) -> Int? {
        let top: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let keypad: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
        return (top.firstIndex(of: keyCode) ?? keypad.firstIndex(of: keyCode)).map { $0 + 1 }
    }

    private func pick(_ index: Int) {
        guard let model, model.commands.indices.contains(index) else { return }
        let (command, run) = (model.commands[index], run)
        popover?.close()
        DispatchQueue.main.async { run?(command) }
    }

    func popoverDidClose(_ notification: Notification) {
        if let keys { NSEvent.removeMonitor(keys) }
        (keys, popover, model, run) = (nil, nil, nil, nil)
    }
}

private struct CommandList: View {
    final class Model: ObservableObject {
        let commands: [SavedCommand]
        /// Under the arrows or the mouse. Return runs it.
        @Published var lit = 0

        init(commands: [SavedCommand]) {
            self.commands = commands
        }

        func move(_ step: Int) {
            lit = (lit + step + commands.count) % commands.count
        }
    }

    @ObservedObject var model: Model
    let folder: String
    let busy: Bool
    let palette: Palette
    let choose: (Int) -> Void

    var body: some View {
        let p = palette
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(p.muted)
                Text(folder).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 8)
                Text("⌥⌘K").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
            }
            .padding(12)
            Rectangle().fill(p.line).frame(height: 1)
            VStack(spacing: 1) {
                ForEach(Array(model.commands.enumerated()), id: \.offset) { index, command in
                    row(index, command, p)
                }
            }
            .padding(6)
            Rectangle().fill(p.line).frame(height: 1)
            // Typed at the shell's prompt, so a program in front, like vim or an agent, would get it instead.
            Text(busy ? "A program is running in this pane. Quit it to run a command." : "1 to 9 or Return to run, Esc to close. Right-click a pane to edit.")
                .font(.system(size: 11))
                .foregroundStyle(busy ? p.waiting : p.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 420)
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .background(p.boxed ? p.surface : p.background)
    }

    private func row(_ index: Int, _ command: SavedCommand, _ p: Palette) -> some View {
        Button { choose(index) } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(p.raised))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(p.line))
                Text(command.name).lineLimit(1).layoutPriority(1)
                Text(command.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(p.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(model.lit == index && !busy ? p.selection : .clear))
            .contentShape(Rectangle())
            .opacity(busy ? 0.5 : 1)
        }
        .buttonStyle(QuietPress())
        .disabled(busy)
        .onClickableHover { if $0 { model.lit = index } }
    }
}
