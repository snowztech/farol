import AppKit
import FarolCore

/// The New Task sheet: what to do, on which branch, with which agent.
final class NewTaskSheet: NSObject, NSTextFieldDelegate {
    private static let agentKey = "newTask.agent"

    private let task = NSTextField()
    private let branch = NSTextField()
    private let agent = NSPopUpButton()
    /// The branch follows the task until you edit it yourself.
    private var branchEdited = false

    /// Calls `start` with a valid branch and the command that launches the agent.
    static func present(in window: NSWindow, directory: String, start: @escaping (String, String) -> Void) {
        let sheet = NewTaskSheet()
        let repo = Git.repoRoot(of: directory).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "repository"
        let base = Git.branch(of: directory) ?? "the current commit"

        let alert = NSAlert()
        alert.messageText = "New task in \(repo)"
        alert.informativeText = "The agent starts in its own worktree, on a new branch from \(base)."
        alert.accessoryView = sheet.form()
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = sheet.task

        alert.beginSheetModal(for: window) { response in
            // The sheet stays alive until here, since the alert's completion holds it.
            guard response == .alertFirstButtonReturn else { return }
            let text = sheet.task.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            guard let name = Worktrees.branchName(from: sheet.branch.stringValue) else {
                return showError(in: window, "No branch name", "Use letters, numbers, dashes or slashes.")
            }
            let choice = NewTask.Agent.allCases[sheet.agent.indexOfSelectedItem]
            UserDefaults.standard.set(choice.rawValue, forKey: agentKey)
            start(name, NewTask.command(choice, task: text))
        }
    }

    private func form() -> NSView {
        task.placeholderString = "What should the agent do?"
        task.delegate = self
        task.lineBreakMode = .byWordWrapping
        task.cell?.wraps = true
        task.cell?.isScrollable = false
        branch.placeholderString = "Branch name"
        branch.delegate = self

        agent.addItems(withTitles: NewTask.Agent.allCases.map(\.title))
        let saved = UserDefaults.standard.string(forKey: Self.agentKey).flatMap(NewTask.Agent.init(rawValue:))
        agent.selectItem(at: NewTask.Agent.allCases.firstIndex(of: saved ?? .claude) ?? 0)

        let grid = NSGridView(views: [
            [label("Task"), task],
            [label("Branch"), branch],
            [label("Agent"), agent],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.column(at: 1).width = 300
        task.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        return grid
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        if field === branch {
            branchEdited = !branch.stringValue.isEmpty
        } else if !branchEdited {
            branch.stringValue = NewTask.branchName(for: task.stringValue)
        }
    }

    /// Return starts the task, and Option-Return adds a line break for longer ones.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === task, selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) else { return false }
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    private static func showError(in window: NSWindow, _ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }
}
