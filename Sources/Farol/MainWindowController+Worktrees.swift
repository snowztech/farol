import AppKit
import FarolCore
import GhosttyTerminal

extension MainWindowController {
    /// Asks for a branch and opens a session in a new worktree of the current session's repo.
    func newWorktreeSession() {
        withRepo(purpose: "the new worktree session") { [weak self] in self?.askForBranch(from: $0) }
    }

    /// ⇧⌘N: a task, a branch and an agent in one sheet. The agent starts in a new worktree with the task as its prompt.
    /// From a folder of repos, it starts in a task folder with a worktree of each repo you pick.
    func newTask() {
        withRepo(purpose: "the new task", orFolderOfRepos: true) { [weak self] directory in
            guard let self, let window = self.window else { return }
            NewTaskSheet.present(in: window, directory: directory, palette: self.state.palette) { branch, command, task, repos in
                self.startWorktreeSession(branch: branch, from: repos, run: command, environment: [NewTask.variable: task])
            }
        }
    }

    /// The current session's repo, or one the user picks when the current session isn't in a repo.
    /// With `orFolderOfRepos`, a folder with repos right inside it does too.
    private func withRepo(purpose: String, orFolderOfRepos: Bool = false, then: @escaping (String) -> Void) {
        // With a sheet already up, a second one would queue behind it and show once the first closes.
        guard let window, window.attachedSheet == nil else { return }
        let directory = store.selected?.directory
        // Git is asked off the main thread, so a slow repo can't freeze the window before anything shows.
        DispatchQueue.global(qos: .userInitiated).async {
            let fits = directory.map { Self.fits($0, orFolderOfRepos: orFolderOfRepos) } ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.attachedSheet == nil else { return }
                if fits, let directory { return then(directory) }
                pickRepo(purpose: purpose, orFolderOfRepos: orFolderOfRepos, then: then)
            }
        }
    }

    private func pickRepo(purpose: String, orFolderOfRepos: Bool, then: @escaping (String) -> Void) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = orFolderOfRepos
            ? "Choose a git repository for \(purpose), or a folder of repos for a task across them."
            : "Choose a git repository for \(purpose)."
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let path = panel.url?.path else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let fits = Self.fits(path, orFolderOfRepos: orFolderOfRepos)
                DispatchQueue.main.async { [weak self] in
                    guard fits else {
                        self?.showError("Not a git repository", orFolderOfRepos
                            ? "Choose a folder inside a git repository, or one with git repositories in it."
                            : "Choose a folder inside a git repository.")
                        return
                    }
                    then(path)
                }
            }
        }
    }

    /// Inside a repo, or with `orFolderOfRepos`, a folder with repos right inside it. Asks git, so off the main thread.
    private static func fits(_ directory: String, orFolderOfRepos: Bool) -> Bool {
        Git.repoRoot(of: directory) != nil || orFolderOfRepos && !TaskFolders.repos(in: directory).isEmpty
    }

    private func askForBranch(from directory: String) {
        // Git is asked off the main thread, so a slow repo can't freeze the window before the sheet shows.
        DispatchQueue.global(qos: .userInitiated).async {
            let repo = Git.repoRoot(of: directory).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "repository"
            let base = Git.branch(of: directory) ?? "the current commit"
            let setup = WorktreeScripts.hasSetup(in: Git.topLevel(of: directory) ?? directory)
            DispatchQueue.main.async { [weak self] in self?.askForBranch(from: directory, repo: repo, base: base, setup: setup) }
        }
    }

    private func askForBranch(from directory: String, repo: String, base: String, setup: Bool) {
        // Checked here too: a second press can arrive while git is still answering the first.
        guard let window, window.attachedSheet == nil else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Branch name"
        let alert = NSAlert()
        alert.messageText = "New worktree session in \(repo)"
        alert.informativeText = "A new branch starts from \(base). An existing branch opens as it is."
            + (setup ? " Farol runs .farol/setup in the new worktree before starting a command." : "")
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
            self?.startWorktreeSession(branch: branch, from: [directory], run: self?.agents.startCommand)
        }
    }

    /// One repo gets a plain worktree. Several get a task folder with a worktree of each.
    private func startWorktreeSession(branch: String, from repos: [String], run command: String?, environment: [String: String] = [:]) {
        store.createWorktreeSession(branch: branch, from: repos, run: command, environment: environment,
                                    copyEnvironmentFiles: worktreeSettings.copyEnvironmentFiles) { [weak self] result in
            if case .failure(let error) = result { self?.showError("Couldn't create the worktree", "\(error)") }
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
        let task = session.taskFolder
        guard let worktree = task ?? session.worktree else { return store.close(session) }
        // Another session still works in this folder.
        guard !store.sessions.contains(where: { $0 !== session && ($0.taskFolder ?? $0.worktree) == worktree }) else {
            return store.close(session)
        }
        // A task asks git about each of its repos, which shouldn't hold up the window.
        DispatchQueue.global(qos: .userInitiated).async {
            let dirty = task != nil
                ? TaskFolders.default.hasUncommittedChanges(worktree)
                : Worktrees.default.hasUncommittedChanges(worktree)
            DispatchQueue.main.async { [weak self] in
                // Unsaved work that git would refuse to delete.
                guard let self, !dirty else { self?.store.close(session); return }
                self.offerToRemove(worktree, isTask: task != nil, closing: session)
            }
        }
    }

    private func offerToRemove(_ worktree: String, isTask: Bool, closing session: Session) {
        guard let window else { return store.close(session) }
        let alert = NSAlert()
        if isTask {
            alert.messageText = "Remove the task's worktrees too?"
            alert.informativeText = "Each repo keeps the branch, so no commits are lost. Only the folder goes."
            alert.addButton(withTitle: "Remove Worktrees")
            alert.addButton(withTitle: "Keep Worktrees")
        } else {
            alert.messageText = "Remove the worktree too?"
            alert.informativeText = "The branch \(session.branch.map { "\($0) " } ?? "")stays, so no commits are lost. Only the folder goes."
            alert.addButton(withTitle: "Remove Worktree")
            alert.addButton(withTitle: "Keep Worktree")
        }
        let repos = isTask ? TaskFolders.repos(in: worktree) : [worktree]
        let teardown = repos.filter { WorktreeScripts.hasTeardown(in: $0) }
        if !teardown.isEmpty {
            let names = teardown.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
            alert.informativeText += " Farol runs .farol/teardown in \(names) before removal."
        }
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.store.close(session)
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        if isTask {
                            try TaskFolders.default.remove(worktree)
                        } else {
                            try Worktrees.default.remove(worktree)
                        }
                    } catch {
                        // Rare now that unsaved work is checked first, so a plain note is enough.
                        DispatchQueue.main.async { [weak self] in
                            if isTask {
                                self?.showError("Some worktrees kept", "\(error) The other repos' worktrees were removed.")
                            } else {
                                self?.showError("Worktree kept", "It couldn't be removed and stays at \(worktree). Nothing was deleted.")
                            }
                        }
                    }
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
