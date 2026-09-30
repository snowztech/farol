import AppKit
import FarolCore
import GhosttyTerminal

extension MainWindowController {
    /// Asks for a branch and opens a session in a new worktree of the current session's repo.
    func newWorktreeSession() {
        withRepo(purpose: "the new worktree session") { [weak self] in self?.askForBranch(from: $0) }
    }

    /// ⇧⌘N: a task, a branch and an agent in one sheet. The agent starts in a new worktree with the task as its prompt.
    func newTask() {
        withRepo(purpose: "the new task") { [weak self] directory in
            guard let self, let window = self.window else { return }
            NewTaskSheet.present(in: window, directory: directory) { branch, command in
                self.startWorktreeSession(branch: branch, from: directory, run: command)
            }
        }
    }

    /// The current session's repo, or one the user picks when the current session isn't in a repo.
    private func withRepo(purpose: String, then: @escaping (String) -> Void) {
        guard let window else { return }
        if let directory = store.selected?.directory, Git.repoRoot(of: directory) != nil {
            return then(directory)
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a git repository for \(purpose)."
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            guard Git.repoRoot(of: path) != nil else {
                self?.showError("Not a git repository", "Choose a folder inside a git repository.")
                return
            }
            then(path)
        }
    }

    private func askForBranch(from directory: String) {
        guard let window else { return }
        let repo = Git.repoRoot(of: directory).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "repository"
        let base = Git.branch(of: directory) ?? "the current commit"

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Branch name"
        let alert = NSAlert()
        alert.messageText = "New worktree session in \(repo)"
        alert.informativeText = "A new branch starts from \(base). An existing branch opens as it is."
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard let branch = Worktrees.branchName(from: field.stringValue) else {
                self?.showError("No branch name", "Use letters, numbers, dashes or slashes.")
                return
            }
            self?.startWorktreeSession(branch: branch, from: directory, run: self?.agents.startCommand)
        }
    }

    private func startWorktreeSession(branch: String, from directory: String, run command: String?) {
        let copyEnvironmentFiles = worktreeSettings.copyEnvironmentFiles
        // Checking out a big repo can take a moment, so keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try Worktrees.default.create(
                    branch: branch, from: directory, copyEnvironmentFiles: copyEnvironmentFiles)
            }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success(let path): self?.store.create(directory: path, run: command)
                case .failure(let error): self?.showError("Couldn't create the worktree", "\(error)")
                }
            }
        }
    }

    /// ⌘W: closes the focused pane, or the whole session when it is the last one.
    func requestClosePane(_ session: Session) {
        if session.panes.fileFocused { return session.panes.closeFile() }
        let terminal = session.panes.focused
        guard session.panes.terminals.count > 1 else { return requestClose(session) }
        guard terminal.hasRunningProcess, let window else {
            _ = session.panes.remove(terminal)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close this pane?"
        alert.informativeText = "A program is still running in it. Closing stops it."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { _ = session.panes.remove(terminal) }
        }
    }

    /// A pane's shell exited: drop the pane, or close the session when it was the last one.
    func paneExited(_ terminal: TerminalView, in session: Session) {
        if !session.panes.remove(terminal) { closeAskingAboutWorktree(session) }
    }

    /// Closes a whole session. Asks first when a program is still running, then whether to remove its worktree.
    func requestClose(_ session: Session) {
        guard session.hasRunningProcess, let window else { return closeAskingAboutWorktree(session) }
        let alert = NSAlert()
        alert.messageText = "Close this session?"
        alert.informativeText = "A program is still running in it. Closing stops it."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            // The next sheet can only start once this one is gone.
            DispatchQueue.main.async { self?.closeAskingAboutWorktree(session) }
        }
    }

    /// Offers to remove the session's worktree, but only when that is possible and safe.
    private func closeAskingAboutWorktree(_ session: Session) {
        if let file = session.panes.file, file.isDirty {
            return file.confirmClose { [weak self] in self?.closeAskingAboutWorktree(session) }
        }
        guard let worktree = session.worktree, let window else {
            store.close(session)
            return
        }
        // Another session still works in this folder, or it holds unsaved work that git would refuse to delete.
        let shared = store.sessions.contains { $0 !== session && $0.worktree == worktree }
        guard !shared, !Worktrees.default.hasUncommittedChanges(worktree) else {
            store.close(session)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Remove the worktree too?"
        alert.informativeText = "The branch \(session.branch.map { "\($0) " } ?? "")stays, so no commits are lost. Only the folder goes."
        alert.addButton(withTitle: "Remove Worktree")
        alert.addButton(withTitle: "Keep Worktree")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                do {
                    try Worktrees.default.remove(worktree)
                } catch {
                    // Rare now that unsaved work is checked first, so a plain note is enough.
                    self.showError("Worktree kept", "It couldn't be removed and stays at \(worktree). Nothing was deleted.")
                }
                self.store.close(session)
            case .alertSecondButtonReturn:
                self.store.close(session)
            default:
                break
            }
        }
    }

    func showError(_ title: String, _ message: String, then: (() -> Void)? = nil) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message.replacingOccurrences(of: "fatal: ", with: "")
        alert.beginSheetModal(for: window) { _ in then?() }
    }
}
