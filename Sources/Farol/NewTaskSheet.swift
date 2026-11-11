import AppKit
import FarolCore
import SwiftUI
import UniformTypeIdentifiers

/// The New Task sheet: what to do, on which branch, with which agent.
struct NewTaskSheet: View {
    private enum Field { case branch, repos }

    let directory: String
    let repo: String
    /// What a new branch starts from, named before anything runs.
    let base: String
    /// New branches start from the remote's default branch, so `base` holds for a run later too.
    let fromDefaultBranch: Bool
    /// The repos inside `directory` when it is a folder of them rather than a repo. Empty for a repo.
    let repos: [String]
    /// From inside a repo: its main checkout, and the repos beside it that "Add repos" offers.
    let root: String?
    /// The checkout this task starts from, which can differ from the main checkout in `root`.
    let checkout: String?
    let siblings: [String]
    /// What each listed repo has checked out, read once when the sheet opens.
    let branches: [String: String]
    /// A tool that lists tickets is set up, so the select is worth holding a place for while they load.
    let expectsTickets: Bool
    let palette: Palette
    /// Gets a valid branch, the command that launches the agent, its task for the command to read, and the repos.
    let start: (String, String, String, [String]) -> Void
    /// Gets a task for later, once or again and again.
    let schedule: (Schedule) -> Void
    let close: () -> Void

    @AppStorage("newTask.agent") private var agent = AgentFolder.Kind.claude.rawValue
    /// Every agent config folder found, so each account is a choice.
    @State private var folders = AgentFolder.find()
    @State private var task = ""
    /// Files and pictures for the agent, pasted or dropped on the task. It gets their paths.
    @State private var attachments: [URL] = []
    @State private var taskHeight = TaskField.height(lines: 3)
    @State private var taskFocused = false
    /// Bumped to put the cursor back in the task, which is AppKit's and so outside `focus`.
    @State private var focusTask = 1
    @State private var branch = ""
    /// The branch follows the task until you edit it yourself.
    @State private var branchEdited = false
    @FocusState private var focus: Field?
    /// Your open Jira tickets and Linear issues, and the repo's open GitHub issues, once they have loaded.
    @State private var loaded: [Ticket]?
    /// What each folder's tickets were the last time, since asking Jira takes seconds.
    /// The sheet opens with these and swaps in the new list when it arrives.
    private static var remembered: [String: [Ticket]] = [:]
    /// Empty without the tools that list them, and the first time, until they load.
    private var tickets: [Ticket] { loaded ?? Self.remembered[directory] ?? [] }
    @State private var picked: Ticket?
    @State private var chosen: Set<String> = []
    @State private var addingRepos = false
    @State private var outsideRepos: [String] = []
    @State private var outsideBranches: [String: String] = [:]
    @State private var choosingRepos = false
    @State private var checkingRepos = false
    @State private var repoError: String?
    @State private var repoQuery = ""
    @State private var pickingTicket = false
    @State private var pickingAgent = false
    @State private var when = TaskTiming.now
    /// The day and time for later, or only the time for a repeat. Tomorrow at 9:00 to begin with.
    @State private var at = TaskTiming.tomorrowMorning
    @State private var weekdays = Schedule.everyDay
    @State private var pickingWhen = false
    @State private var query = ""
    @FocusState private var searching: Bool

    static func present(in window: NSWindow, directory: String, fromDefaultBranch: Bool, palette: Palette, start: @escaping (String, String, String, [String]) -> Void,
                        schedule: @escaping (Schedule) -> Void) {
        // Git is asked off the main thread, so a slow repo can't freeze the window before the sheet shows.
        DispatchQueue.global(qos: .userInitiated).async {
            let root = Git.repoRoot(of: directory)
            let checkout = root == nil ? nil : Git.topLevel(of: directory)
            let repos = root == nil ? TaskFolders.repos(in: directory) : []
            let siblings = root.map { TaskFolders.repos(in: ($0 as NSString).deletingLastPathComponent) } ?? []
            var branches = (repos + siblings).reduce(into: [String: String]()) { $0[$1] = TaskFolders.branch(of: $1) }
            let current = Git.branch(of: directory)
            // The current repo starts from the checkout you are in, which may be a worktree on another branch than its main one.
            if let root { branches[root] = current }
            let repo = URL(fileURLWithPath: root ?? directory).lastPathComponent
            let base = Worktrees.startPoint(in: directory, fromDefaultBranch: fromDefaultBranch)
            let expectsTickets = Jira.isSetUp || Linear.isSetUp || Forge.detect(in: directory)?.listsIssues == true
            DispatchQueue.main.async { [weak window] in
                // Checked here too: a second press can arrive while git is still answering the first.
                guard let window, window.attachedSheet == nil else { return }
                let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
                let view = NewTaskSheet(
                    directory: directory, repo: repo, base: base, fromDefaultBranch: fromDefaultBranch, repos: repos, root: root, checkout: checkout,
                    siblings: siblings, branches: branches, expectsTickets: expectsTickets,
                    palette: palette, start: start, schedule: schedule,
                    close: { [weak window, weak sheet] in sheet.map { window?.endSheet($0) } })
                let host = NSHostingController(rootView: view)
                // The sheet grows with the task as it wraps onto more lines.
                host.sizingOptions = [.preferredContentSize]
                sheet.contentViewController = host
                window.beginSheet(sheet)
            }
        }
    }

    private var text: String { task.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The picked ticket in full, which the sheet doesn't show, the attachments' paths, one a line as the phone sends them, then what you typed.
    private var prompt: String {
        [picked?.task ?? "", attachments.map(\.path).joined(separator: "\n"), text].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    private var canStart: Bool {
        !prompt.isEmpty && name != nil && !sources.isEmpty && duplicateRepoName == nil && !checkingRepos && (starts != .later || at > .now)
    }
    private var name: String? { Worktrees.branchName(from: branch) }
    private var choice: AgentFolder { AgentFolder.choice(agent, in: folders) ?? folders[0] }
    /// The checklist: the folder's repos, or the current repo's neighbours once you ask to add some.
    private var listed: [String] {
        let nearby: [String]
        if !repos.isEmpty {
            nearby = repos
        } else if addingRepos, let root {
            nearby = [root] + siblings.filter { $0 != root }
        } else {
            nearby = []
        }
        return nearby + outsideRepos.filter { !nearby.contains($0) }
    }
    /// Where the worktrees come from, in the folder's order. The current repo keeps its own checkout, so its branch is the base.
    private var sources: [String] {
        listed.isEmpty ? [directory] : listed.filter(chosen.contains).map { $0 == root ? directory : $0 }
    }
    private var duplicateRepoName: String? { TaskFolders.duplicateName(in: listed.filter(chosen.contains)) }
    private var setupNames: [String] {
        sources.compactMap { source in
            let folder = source == directory ? checkout ?? directory : source
            return WorktreeScripts.hasSetup(in: folder) ? URL(fileURLWithPath: folder).lastPathComponent : nil
        }
    }
    private var starts: TaskTiming { when }
    /// Several repos get a task folder each run, with a worktree of each.
    private var several: Bool { !repos.isEmpty || sources.count > 1 }
    private var hour: Int { Calendar.current.component(.hour, from: at) }
    private var minute: Int { Calendar.current.component(.minute, from: at) }
    private var whenLabel: String { starts.label(at: at, weekdays: weekdays) }
    /// A run later branches from the repo itself, since the worktree you're in may be gone by then.
    private var laterBase: String {
        guard !fromDefaultBranch, let root, let checkout, checkout != root else { return base }
        return "what \(repo) has checked out then"
    }

    private var subtitle: String {
        let start = whenLabel.prefix(1).lowercased() + whenLabel.dropFirst()
        let rule = weekdays == Schedule.everyDay || weekdays == Schedule.workweek ? start : "on \(start)"
        switch (starts, several) {
        case (.later, false): return "Starts \(start) in its own worktree, on a new branch from \(laterBase)."
        case (.repeats, false): return "Starts \(rule), each time in its own worktree from \(laterBase)."
        case (.later, true): return "Starts \(start) with a worktree of each repo you pick, side by side in one folder."
        case (.repeats, true): return "Starts \(rule), each time with new worktrees of the repos you pick, side by side in one folder."
        case (.now, _): break
        }
        if repos.isEmpty, sources.count < 2 { return "The agent starts in its own worktree, on a new branch from \(base)." }
        return "Each repo you pick gets its own worktree on the same branch, side by side in one folder. The agent starts there and sees them all."
    }

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(title: "New task in \(repo)", palette: p) {
                    Text(subtitle).fixedSize(horizontal: false, vertical: true)
                }
                if !tickets.isEmpty {
                    ticketSelect(p)
                        // The list is last time's until the new one arrives. Left of the select's own arrows.
                        .overlay(alignment: .trailing) {
                            if loaded == nil { ProgressView().controlSize(.mini).padding(.trailing, 32) }
                        }
                } else if expectsTickets {
                    ticketPlaceholder(p)
                }
                if let picked, !picked.description.isEmpty { ticketPreview(picked.description, p) }
                VStack(alignment: .leading, spacing: 6) {
                    TaskField(
                        placeholder: picked == nil ? "What should the agent do?" : "Anything to add? The agent gets the ticket as it is.",
                        text: $task, height: $taskHeight, focusRequest: focusTask, palette: p,
                        focused: { taskFocused = $0 },
                        attach: { urls in attachments += urls.filter { !attachments.contains($0) } },
                        submit: { if canStart { startTask() } },
                        cancel: close)
                        .frame(height: taskHeight)
                        .sheetField(p, focused: taskFocused)
                        .onChange(of: task) { _, task in
                            if !branchEdited { branch = NewTask.branchName(for: task) }
                        }
                    if !attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(attachments, id: \.self) { url in
                                    AttachmentChip(url: url, palette: p) { attachments.removeAll { $0 == url } }
                                }
                            }
                        }
                    }
                    Text("↩ \(starts == .now ? "start" : "schedule") · ⇧↩ new line · paste or drop pictures and files")
                        .font(.system(size: 11))
                        .foregroundStyle(p.muted)
                }
                if !listed.isEmpty {
                    repoChecklist(p)
                } else if let root {
                    addReposLink(root, p)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(p.muted)
                        // Only typing goes through here, so the name filled in from the task doesn't count as your edit.
                        TextField("Branch name", text: Binding(get: { branch }, set: {
                            branch = $0
                            branchEdited = !$0.isEmpty
                        }))
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .branch)
                    }
                    .sheetField(p, focused: focus == .branch)
                    if !branch.isEmpty, name == nil {
                        Text("Use letters, numbers, dashes or slashes.").font(.system(size: 12)).foregroundStyle(p.muted)
                    } else if starts == .repeats, let name {
                        Text("Each run gets the day after it, like \(name)-\(Self.today).").font(.system(size: 12)).foregroundStyle(p.muted)
                    }
                }
                agentSelect(p)
                if !setupNames.isEmpty {
                    Text("Runs .farol/setup in \(setupNames.joined(separator: ", ")) before the agent starts.")
                        .font(.system(size: 12))
                        .foregroundStyle(p.muted)
                }
            }
            .padding(20)
            Rectangle().fill(p.line).frame(height: 1)
            HStack {
                whenSelect(p)
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(SheetButton(palette: p, primary: false))
                    .keyboardShortcut(.cancelAction)
                Button(starts == .now ? "Start" : "Schedule", action: startTask)
                    .buttonStyle(SheetButton(palette: p, primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .frame(width: 460)
        .sheetBackground(p)
        .ignoresSafeArea()
        .fileImporter(isPresented: $choosingRepos, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): addRepositories(urls)
            case .failure(let error): repoError = error.localizedDescription
            }
        }
        .fileDialogMessage("Choose Git repositories or folders inside them")
        .fileDialogConfirmationLabel("Add")
        .fileDialogDefaultDirectory(URL(fileURLWithPath: directory))
        .task {
            let directory = directory
            // All at once, since each waits on its own server. Linear's only when it's set up, so nobody without it pays for a shell.
            let board = Jira.Board(line: UserDefaults.standard.string(forKey: Jira.boardKey) ?? "")
            async let jira = Task.detached { (try? Jira.tickets(on: board)) ?? [] }.value
            async let linear = Task.detached { Linear.isSetUp ? (try? Linear.tickets()) ?? [] : [] }.value
            async let issues = Task.detached { Forge.detect(in: directory)?.issues(in: directory) ?? [] }.value
            let tickets = await jira + linear + issues
            loaded = tickets
            Self.remembered[directory] = tickets
        }
    }

    private var matches: [Ticket] {
        let words = query.lowercased().split(separator: " ")
        return tickets.filter { ticket in
            let text = "\(ticket.key) \(ticket.summary)".lowercased()
            return words.allSatisfy(text.contains)
        }
    }

    /// Holds the select's place while the tickets load, so the sheet doesn't grow under your hands when they arrive.
    private func ticketPlaceholder(_ p: Palette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "ticket")
            Text(loaded == nil ? "Loading tickets…" : "No open tickets")
            Spacer(minLength: 0)
            if loaded == nil { ProgressView().controlSize(.mini) }
        }
        .foregroundStyle(p.muted.opacity(0.6))
        .sheetField(p, focused: false)
    }

    /// What the agent will read. Anyone can open an issue on a public repo, so the text is worth a look before it becomes instructions.
    private func ticketPreview(_ description: String, _ p: Palette) -> some View {
        let text = Text(description)
            .font(.system(size: 12))
            .foregroundStyle(p.muted)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        // Short ones show whole, long ones scroll, so the sheet stays on screen.
        return ViewThatFits(in: .vertical) {
            text.fixedSize(horizontal: false, vertical: true)
            ScrollView { text }
        }
        .frame(maxHeight: 160)
        .sheetField(p, focused: false)
    }

    private func ticketSelect(_ p: Palette) -> some View {
        SheetSelect(palette: p, open: $pickingTicket) {
            if let picked {
                ticketLabel(picked, p)
            } else {
                Image(systemName: "ticket").foregroundStyle(p.muted)
                Text("Start from a ticket").foregroundStyle(p.muted)
            }
        } choices: {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(p.muted)
                    // Return takes the first match, so a ticket is a few letters away.
                    TextField("Search \(tickets.count) tickets", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searching)
                        .onSubmit { matches.first.map(fill(from:)) }
                }
                .padding(12)
                Rectangle().fill(p.line).frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if picked != nil, query.isEmpty {
                            SheetChoice(palette: p, choose: dropTicket) {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                Text("No ticket")
                            }
                            .foregroundStyle(p.muted)
                        }
                        ForEach(matches) { ticket in
                            SheetChoice(palette: p) { fill(from: ticket) } label: { ticketLabel(ticket, p) }
                        }
                        if matches.isEmpty {
                            Text("No ticket matches.").foregroundStyle(p.muted).padding(.vertical, 12)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 264)
            }
            .frame(width: 420)
            .onAppear { searching = true }
        }
    }

    /// The repos in the folder, to tick the ones the task touches.
    private func repoChecklist(_ p: Palette) -> some View {
        let shown = shownRepos
        let list = VStack(spacing: 1) {
            ForEach(shown, id: \.self) { repo in
                TaskRepoChoice(name: URL(fileURLWithPath: repo).lastPathComponent,
                               path: repo == root ? checkout ?? repo : repo,
                               branch: outsideBranches[repo] ?? branches[repo], selected: chosen.contains(repo), palette: p) {
                    toggle(repo)
                }
            }
            if shown.isEmpty {
                Text("No repo matches.").foregroundStyle(p.muted).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(chosen.isEmpty ? "Repos" : "Repos · \(chosen.count) of \(listed.count)").foregroundStyle(p.muted)
                Spacer()
                // On what the search shows, so "All" never ticks repos you can't see.
                let all = !shown.isEmpty && Set(shown).isSubset(of: chosen)
                Button(all ? "None" : "All") {
                    if all { chosen.subtract(shown) } else { chosen.formUnion(shown) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.muted)
                .disabled(shown.isEmpty)
            }
            .font(.system(size: 12))
            VStack(spacing: 0) {
                if listed.count > Self.searchAbove {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(p.muted)
                        // Return ticks the first match and clears the search for the next one.
                        TextField("Search \(listed.count) repos", text: $repoQuery)
                            .textFieldStyle(.plain)
                            .focused($focus, equals: .repos)
                            .onSubmit {
                                guard let first = shownRepos.first else { return }
                                toggle(first)
                                repoQuery = ""
                            }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    Rectangle().fill(p.line).frame(height: 1)
                }
                // A few show whole, a long list scrolls, so the sheet stays on screen.
                ViewThatFits(in: .vertical) {
                    list.fixedSize(horizontal: false, vertical: true)
                    ScrollView { list }
                }
                .frame(maxHeight: 200)
                .padding(6)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(p.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focus == .repos ? p.muted : p.line))
            Button {
                repoError = nil
                choosingRepos = true
            } label: {
                Label("Choose repository…", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(p.muted)
            .disabled(checkingRepos)
            if checkingRepos {
                Label("Checking repositories…", systemImage: "hourglass")
                    .font(.system(size: 12))
                    .foregroundStyle(p.muted)
            }
            if let duplicateRepoName {
                Text("Two selected repositories are named \(duplicateRepoName). Choose one of them.")
                    .font(.system(size: 12))
                    .foregroundStyle(p.removed)
            }
            if let repoError {
                Text(repoError).font(.system(size: 12)).foregroundStyle(p.removed)
            }
        }
    }

    /// The search only shows up past this many repos, where scrolling for one gets slow.
    private static let searchAbove = 8

    private var shownRepos: [String] {
        let words = repoQuery.lowercased().split(separator: " ")
        return listed.filter { repo in
            let name = URL(fileURLWithPath: repo).lastPathComponent.lowercased()
            return words.allSatisfy(name.contains)
        }
    }

    private func toggle(_ repo: String) {
        if chosen.contains(repo) { chosen.remove(repo) } else { chosen.insert(repo) }
    }

    /// One quiet line, since most tasks stay in one repo. It opens the checklist with this repo already ticked.
    private func addReposLink(_ root: String, _ p: Palette) -> some View {
        return Button {
            chosen = [root]
            addingRepos = true
            if siblings.allSatisfy({ $0 == root }) { choosingRepos = true }
        } label: {
            Label("Add repositories", systemImage: "plus").font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(p.muted)
    }

    private func addRepositories(_ urls: [URL]) {
        checkingRepos = true
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [(path: String, branch: String?)] = []
            var invalid = 0
            for url in urls {
                guard let root = Git.repoRoot(of: url.path) else { invalid += 1; continue }
                if !found.contains(where: { $0.path == root }) {
                    found.append((root, TaskFolders.branch(of: root)))
                }
            }
            DispatchQueue.main.async {
                checkingRepos = false
                for repo in found {
                    if !listed.contains(repo.path) { outsideRepos.append(repo.path) }
                    if repo.path != root, let branch = repo.branch { outsideBranches[repo.path] = branch }
                    chosen.insert(repo.path)
                }
                repoError = invalid == 0 ? nil : "Choose a folder inside a Git repository."
            }
        }
    }

    /// The mark of where it comes from, its key, then as much of its title as fits on the line.
    private func ticketLabel(_ ticket: Ticket, _ p: Palette) -> some View {
        HStack(spacing: 8) {
            ToolTile(source: ticket.source, size: 16)
            Text(ticket.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.muted).fixedSize()
            Text(ticket.summary).lineLimit(1).truncationMode(.tail)
        }
    }

    private static var today: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// When the task starts, beside the button it changes, like a mail app's Send Later.
    private func whenSelect(_ p: Palette) -> some View {
        WhenButton(label: whenLabel, waiting: starts != .now, palette: p) { pickingWhen.toggle() }
            .popover(isPresented: $pickingWhen, arrowEdge: .top) {
                WhenChoices(when: $when, at: $at, weekdays: $weekdays, offersNow: true, palette: p) { pickingWhen = false }
            }
    }

    private func agentSelect(_ p: Palette) -> some View {
        SheetSelect(palette: p, open: $pickingAgent) {
            ToolTile(agent: choice.kind, size: 18)
            Text(choice.label)
        } choices: {
            VStack(spacing: 1) {
                ForEach(folders, id: \.id) { option in
                    SheetChoice(palette: p) {
                        agent = option.id
                        pickingAgent = false
                    } label: {
                        ToolTile(agent: option.kind, size: 16)
                        Text(option.label)
                        Spacer()
                        if option.id == choice.id { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                    }
                }
            }
            .padding(6)
            .frame(width: 220)
        }
    }

    private func startTask() {
        guard canStart, let name else { return }
        if starts != .now {
            let title = picked?.summary ?? text.components(separatedBy: .newlines).first ?? name
            // The repo itself, not a worktree you happen to be in, which may be gone by the next run.
            var task = Schedule(name: String(title.prefix(48)), task: prompt, repos: sources.map { $0 == directory ? root ?? $0 : $0 },
                                branch: name, agent: choice.isDefault ? choice.kind.rawValue : choice.id,
                                weekdays: starts == .repeats ? weekdays : Schedule.everyDay, hour: hour, minute: minute, since: .now)
            if starts == .later { task.once = at }
            close()
            return schedule(task)
        }
        let command = choice.command() + " \"$\(NewTask.variable)\""
        close()
        // The worktree may fail and show why, which needs this sheet gone first.
        DispatchQueue.main.async { [sources, prompt] in start(name, command, prompt, sources) }
    }

    private func fill(from ticket: Ticket) {
        picked = ticket
        branch = ticket.branch
        // Counts as your edit, so the branch keeps the ticket's key whatever you type next.
        branchEdited = true
        pickingTicket = false
        query = ""
        focusTask += 1
    }

    private func dropTicket() {
        picked = nil
        branchEdited = false
        branch = NewTask.branchName(for: task)
        pickingTicket = false
        focusTask += 1
    }
}

/// A file or picture going to the agent, with a way to take it back.
private struct AttachmentChip: View {
    let url: URL
    let palette: Palette
    let remove: () -> Void

    /// Read once, since the sheet redraws on every key typed in the task.
    @State private var thumbnail: NSImage?

    /// A pasted picture is saved under a made-up name, which says nothing.
    private var name: String {
        url.deletingLastPathComponent().path == TaskTextView.inbox.folder.path ? "Pasted picture" : url.lastPathComponent
    }

    var body: some View {
        HStack(spacing: 6) {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill().frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "doc").foregroundStyle(palette.muted)
            }
            Text(name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.muted)
            }
            .buttonStyle(.plain)
            .hoverTip("Remove")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.line))
        .hoverTip(url.path)
        .task(id: url) {
            guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return }
            thumbnail = NSImage(contentsOf: url)
        }
    }
}

private struct TaskRepoChoice: View {
    let name: String
    let path: String
    let branch: String?
    let selected: Bool
    let palette: Palette
    let choose: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? palette.text : palette.muted)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text("from \(branch ?? "current commit")")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? palette.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onClickableHover { hovering = $0 }
        .help(path)
    }
}

/// The quiet footer button that says when the task starts.
struct WhenButton: View {
    let label: String
    let waiting: Bool
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // The same clock either way, so the control is easy to find again. Only its weight says a time is set.
                Image(systemName: "clock").font(.system(size: 11, weight: .medium))
                Text(label)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.muted)
            }
            .font(.system(size: 12))
            .foregroundStyle(waiting || hovering ? palette.text : palette.muted)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? palette.raised : waiting ? palette.surface : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(waiting ? palette.line : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onClickableHover { hovering = $0 }
        .hoverTip("When it starts")
    }
}

/// When a task runs. Now is only for a new task: a saved one runs now from its row instead.
enum TaskTiming: Hashable {
    case now, later, repeats

    static var tomorrowMorning: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    var title: String {
        switch self {
        case .now: "Now"
        case .later: "Once"
        case .repeats: "Repeat"
        }
    }

    /// What the When button says: Now, Tomorrow at 9:00, Mon, Thu at 9:00.
    func label(at: Date, weekdays: Set<Int>) -> String {
        let calendar = Calendar.current
        let time = Schedule.clock(hour: calendar.component(.hour, from: at), minute: calendar.component(.minute, from: at))
        switch self {
        case .now: return "Now"
        case .repeats:
            let days = Schedule.days(weekdays)
            return "\(days.prefix(1).uppercased() + days.dropFirst()) at \(time)"
        case .later:
            if calendar.isDateInToday(at) { return "Today at \(time)" }
            if calendar.isDateInTomorrow(at) { return "Tomorrow at \(time)" }
            return "\(at.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) at \(time)"
        }
    }

    var symbol: String {
        switch self {
        case .now: "play"
        case .later: "clock"
        case .repeats: "repeat"
        }
    }
}

/// The choices of when, then the day and time or only the time, for New Task's footer and a task's row.
struct WhenChoices: View {
    @Binding var when: TaskTiming
    @Binding var at: Date
    @Binding var weekdays: Set<Int>
    let offersNow: Bool
    let palette: Palette
    /// Picking Now leaves nothing more to set.
    let done: () -> Void

    @State private var pickingDay = false
    @State private var pickingTime = false
    @State private var typed = ""
    @FocusState private var typing: Bool

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 1) {
            ForEach(offersNow ? [TaskTiming.now, .later, .repeats] : [.later, .repeats], id: \.self) { option in
                SheetChoice(palette: p) {
                    when = option
                    if option == .later, at <= .now { at = TaskTiming.tomorrowMorning }
                    if option == .now { done() }
                } label: {
                    Image(systemName: option.symbol).frame(width: 16).foregroundStyle(p.muted)
                    Text(option.title)
                    // One spacer in the row, so the check sits at the end and not halfway.
                    if option == when {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            if when != .now {
                Rectangle().fill(p.line).frame(height: 1).padding(.vertical, 5)
                if when == .repeats { dayToggles(p) }
                // A day in words and a time apart, since 08/11 reads as August in one country and November in the next.
                HStack(spacing: 6) {
                    if when == .later {
                        SheetSelect(palette: p, open: $pickingDay, compact: true) {
                            Text(Self.dayName(daysAhead)).lineLimit(1)
                        } choices: {
                            MonthGrid(picked: at, palette: p) { day in
                                let calendar = Calendar.current
                                set(day: calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: day).day ?? 0, minutes: minutes)
                                pickingDay = false
                            }
                        }
                    }
                    timeField(p)
                        .frame(width: when == .later ? 96 : nil)
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
                Text(firstRun)
                    .font(.system(size: 11))
                    .foregroundStyle(p.muted)
                    // The popover sizes before the text wraps, which cut the second line to an ellipsis.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .padding(6)
        .frame(width: 260)
        .background(p.background)
    }

    /// The days a repeat runs on, in the order of the user's week. The last one can't be turned off, so a repeat always runs.
    private func dayToggles(_ p: Palette) -> some View {
        let names = Calendar.current.veryShortStandaloneWeekdaySymbols
        let long = Calendar.current.weekdaySymbols
        return HStack(spacing: 4) {
            ForEach(Schedule.week(), id: \.self) { day in
                DayToggle(letter: names[day - 1], on: weekdays.contains(day), palette: p) {
                    if weekdays.contains(day) {
                        if weekdays.count > 1 { weekdays.remove(day) }
                    } else {
                        weekdays.insert(day)
                    }
                }
                .hoverTip(long[day - 1])
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 6)
    }

    /// Typed for any minute, like 9:05 or 21h30. The list only offers quarter hours, to pick a round time in one click.
    private func timeField(_ p: Palette) -> some View {
        HStack(spacing: 8) {
            TextField("", text: $typed)
                .textFieldStyle(.plain)
                .monospacedDigit()
                .focused($typing)
                .onSubmit(commitTyped)
            Button { pickingTime.toggle() } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(p.muted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $pickingTime, arrowEdge: .bottom) {
                timeList(p).font(.system(size: 13)).foregroundStyle(p.text).background(p.background)
            }
        }
        .sheetField(p, focused: typing || pickingTime, padding: 6)
        .onAppear { typed = Self.clock(minutes) }
        .onChange(of: minutes) { _, now in if !typing { typed = Self.clock(now) } }
        .onChange(of: typing) { _, now in if !now { commitTyped() } }
    }

    /// A time that doesn't read as one goes back to the last good one.
    private func commitTyped() {
        if let picked = Schedule.minutes(typed: typed) { set(day: daysAhead, minutes: picked) }
        typed = Self.clock(minutes)
    }

    /// Every quarter of an hour, opened on the one picked. Today, for a task that runs once, it starts at the next five minutes.
    private func timeList(_ p: Palette) -> some View {
        let soon = when == .later && daysAhead == 0 ? Self.soon : nil
        let times = (soon.map { [$0] } ?? []) + stride(from: 0, to: 24 * 60, by: 15).filter { $0 > (soon ?? -1) }
        return ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(times, id: \.self) { time in
                        SheetChoice(palette: p) {
                            set(day: daysAhead, minutes: time)
                            pickingTime = false
                        } label: { picked(Self.clock(time), time == minutes).monospacedDigit() }
                        .id(time)
                    }
                }
                .padding(6)
            }
            .frame(width: 120, height: 240)
            .onAppear { reader.scrollTo(times.last { $0 <= minutes } ?? times.first, anchor: .center) }
        }
    }

    /// The next five minutes from now, in minutes into today. Past 23:55 there's no more of today to offer.
    private static var soon: Int? {
        let now = Calendar.current.dateComponents([.hour, .minute], from: .now)
        let next = ((now.hour ?? 0) * 60 + (now.minute ?? 0)) / 5 * 5 + 5
        return next < 24 * 60 ? next : nil
    }

    private func picked(_ title: String, _ chosen: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if chosen { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
        }
    }

    /// When it really starts, worked out for you: weekdays picked on a Friday evening start on Monday.
    private var firstRun: String {
        let rule = Schedule(name: "", task: "", repos: [], branch: "", agent: "", weekdays: weekdays, hour: minutes / 60, minute: minutes % 60,
                            since: .now)
        let next = when == .later ? at : rule.next(after: .now)
        let calendar = Calendar.current
        let day = calendar.isDateInToday(next) ? "today" : calendar.isDateInTomorrow(next) ? "tomorrow"
            : next.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        return "\(when == .later ? "Runs" : "First run") \(day) at \(Self.clock(minutes)).\nFarol opens for it, even if you quit."
    }

    private var minutes: Int {
        let time = Calendar.current.dateComponents([.hour, .minute], from: at)
        return (time.hour ?? 9) * 60 + (time.minute ?? 0)
    }

    private var daysAhead: Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: at)).day ?? 0
    }

    private static func clock(_ minutes: Int) -> String { Schedule.clock(hour: minutes / 60, minute: minutes % 60) }

    /// Today with its time gone moves to the next five minutes, so a task that runs once is never in the past and today stays pickable late in the evening.
    private func set(day ahead: Int, minutes: Int) {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: ahead, to: calendar.startOfDay(for: .now)) ?? .now
        let picked = calendar.date(byAdding: .minute, value: minutes, to: day) ?? day
        guard when == .later, picked <= .now else { return at = picked }
        let next = Self.soon ?? 24 * 60
        at = calendar.date(byAdding: .minute, value: next, to: calendar.startOfDay(for: .now)) ?? picked
    }

    /// Today, Tomorrow, then like Sun 8 Nov, with the year once it isn't this one.
    private static func dayName(_ ahead: Int) -> String {
        switch ahead {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default:
            let calendar = Calendar.current
            let day = calendar.date(byAdding: .day, value: ahead, to: .now) ?? .now
            let format = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
            return day.formatted(calendar.isDate(day, equalTo: .now, toGranularity: .year) ? format : format.year())
        }
    }
}

/// A month to pick a day from, in the sheet's own quiet colors rather than the system's blue. Days gone are dimmed.
private struct MonthGrid: View {
    let palette: Palette
    let picked: Date
    let choose: (Date) -> Void
    @State private var month: Date

    init(picked: Date, palette: Palette, choose: @escaping (Date) -> Void) {
        self.picked = picked
        self.palette = palette
        self.choose = choose
        _month = State(initialValue: Calendar.current.dateInterval(of: .month, for: picked)?.start ?? picked)
    }

    var body: some View {
        let calendar = Calendar.current
        let first = calendar.dateInterval(of: .month, for: .now)?.start ?? .now
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.system(size: 13, weight: .medium))
                Spacer()
                CloseButton(symbol: "chevron.left", help: "Previous month", palette: palette) { step(-1) }
                    .disabled(month <= first)
                    .opacity(month <= first ? 0.3 : 1)
                CloseButton(symbol: "chevron.right", help: "Next month", palette: palette) { step(1) }
            }
            .padding(.leading, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 2), count: 7), spacing: 2) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in
                    Text(name).font(.system(size: 10)).foregroundStyle(palette.muted).frame(height: 18)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        DayCell(day: day, chosen: calendar.isDate(day, inSameDayAs: picked), palette: palette) { choose(day) }
                    } else {
                        Color.clear.frame(height: 26)
                    }
                }
            }
        }
        .padding(8)
    }

    private func step(_ months: Int) {
        month = Calendar.current.date(byAdding: .month, value: months, to: month) ?? month
    }

    /// One letter a day, starting where the user's week starts.
    private var weekdays: [String] {
        let calendar = Calendar.current
        let names = calendar.veryShortStandaloneWeekdaySymbols
        return Array(names[(calendar.firstWeekday - 1)...] + names[..<(calendar.firstWeekday - 1)])
    }

    /// The month's days, after blanks up to its first weekday.
    private var days: [Date?] {
        let calendar = Calendar.current
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: month) }
    }
}

private struct DayCell: View {
    let day: Date
    let chosen: Bool
    let palette: Palette
    let choose: () -> Void

    @State private var hovering = false

    var body: some View {
        let calendar = Calendar.current
        let gone = day < calendar.startOfDay(for: .now)
        Button(action: choose) {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 12, weight: chosen ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(chosen ? palette.background : gone ? palette.muted.opacity(0.5) : palette.text)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? palette.text : hovering && !gone ? palette.raised : .clear))
                // A dot, as in Calendar. A box around today read as a second pick or as a day you can't have.
                .overlay(alignment: .bottom) {
                    if calendar.isDateInToday(day) {
                        Circle().fill(chosen ? palette.background : palette.text).frame(width: 3, height: 3).padding(.bottom, 3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(gone)
        .onClickableHover { hovering = $0 }
    }
}

/// One day of the week a repeat can run on, filled when it does.
private struct DayToggle: View {
    let letter: String
    let on: Bool
    let palette: Palette
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            Text(letter)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? palette.background : palette.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? palette.text : hovering ? palette.raised : palette.surface))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onClickableHover { hovering = $0 }
    }
}
