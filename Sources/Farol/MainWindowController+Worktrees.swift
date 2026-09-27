import AppKit
import FarolCore

extension MainWindowController {
    /// Asks for a branch and opens a session in a new worktree of the current session's repo.
    func newWorktreeSession() {
        guard let window else { return }
        if let directory = store.selected?.directory, Git.repoRoot(of: directory) != nil {
            askForBranch(from: directory)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a git repository for the new worktree session."
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            guard Git.repoRoot(of: path) != nil else {
                self?.showError("Not a git repository", "Choose a folder inside a git repository.")
                return
            }
            self?.askForBranch(from: path)
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
            // Checking out a big repo can take a moment, so keep it off the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try Worktrees.default.create(branch: branch, from: directory) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let path): self?.store.create(directory: path)
                    case .failure(let error): self?.showError("Couldn't create the worktree", "\(error)")
                    }
                }
            }
        }
    }

    /// Closes a session. For a worktree session, first asks whether to remove the worktree folder.
    func requestClose(_ session: Session) {
        guard let worktree = session.worktree, let window else {
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
                    self.store.close(session)
                } catch {
                    let reason = "Git would not remove it, usually because of uncommitted changes. It stays at \(worktree)."
                    self.showError("Worktree kept", reason + "\n\n\(error)") { self.store.close(session) }
                }
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
