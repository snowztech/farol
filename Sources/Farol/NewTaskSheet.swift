import AppKit
import FarolCore
import SwiftUI

/// The New Task sheet: what to do, on which branch, with which agent.
struct NewTaskSheet: View {
    private enum Field { case task, branch, repos }

    let directory: String
    let repo: String
    let base: String
    /// The repos inside `directory` when it is a folder of them rather than a repo. Empty for a repo.
    let repos: [String]
    /// From inside a repo: its main checkout, and the repos beside it that "Add repos" offers.
    let root: String?
    let siblings: [String]
    /// What each listed repo has checked out, read once when the sheet opens.
    let branches: [String: String]
    /// A tool that lists tickets is set up, so the select is worth holding a place for while they load.
    let expectsTickets: Bool
    let palette: Palette
    /// Gets a valid branch, the command that launches the agent, its task for the command to read, and the repos.
    let start: (String, String, String, [String]) -> Void
    let close: () -> Void

    @AppStorage("newTask.agent") private var agent = AgentFolder.Kind.claude.rawValue
    /// Every Claude Code and Codex config folder found, so each account is a choice.
    @State private var folders = AgentFolder.find()
    @State private var task = ""
    @State private var branch = ""
    /// The branch follows the task until you edit it yourself.
    @State private var branchEdited = false
    @FocusState private var focus: Field?
    /// Your open Jira tickets and the repo's open GitHub issues, once they have loaded.
    @State private var loaded: [Ticket]?
    /// What each folder's tickets were the last time, since asking Jira takes seconds.
    /// The sheet opens with these and swaps in the new list when it arrives.
    private static var remembered: [String: [Ticket]] = [:]
    /// Empty without the tools that list them, and the first time, until they load.
    private var tickets: [Ticket] { loaded ?? Self.remembered[directory] ?? [] }
    @State private var picked: Ticket?
    @State private var chosen: Set<String> = []
    @State private var addingRepos = false
    @State private var repoQuery = ""
    @State private var pickingTicket = false
    @State private var pickingAgent = false
    @State private var query = ""
    @FocusState private var searching: Bool

    static func present(in window: NSWindow, directory: String, palette: Palette, start: @escaping (String, String, String, [String]) -> Void) {
        // Git is asked off the main thread, so a slow repo can't freeze the window before the sheet shows.
        DispatchQueue.global(qos: .userInitiated).async {
            let root = Git.repoRoot(of: directory)
            let repos = root == nil ? TaskFolders.repos(in: directory) : []
            let siblings = root.map { TaskFolders.repos(in: ($0 as NSString).deletingLastPathComponent) } ?? []
            var branches = (repos + siblings).reduce(into: [String: String]()) { $0[$1] = TaskFolders.branch(of: $1) }
            let current = Git.branch(of: directory)
            // The current repo starts from the checkout you are in, which may be a worktree on another branch than its main one.
            if let root { branches[root] = current }
            let repo = URL(fileURLWithPath: root ?? directory).lastPathComponent
            let base = current ?? "the current commit"
            let expectsTickets = Jira.isSetUp || Forge.detect(in: directory)?.listsIssues == true
            DispatchQueue.main.async { [weak window] in
                // Checked here too: a second press can arrive while git is still answering the first.
                guard let window, window.attachedSheet == nil else { return }
                let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
                let view = NewTaskSheet(
                    directory: directory, repo: repo, base: base, repos: repos, root: root, siblings: siblings, branches: branches, expectsTickets: expectsTickets,
                    palette: palette, start: start,
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
    /// The picked ticket in full, which the sheet doesn't show, then what you typed.
    private var prompt: String {
        [picked?.task ?? "", text].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    private var name: String? { Worktrees.branchName(from: branch) }
    private var choice: AgentFolder { AgentFolder.choice(agent, in: folders) ?? folders[0] }
    /// The checklist: the folder's repos, or the current repo's neighbours once you ask to add some.
    private var listed: [String] { !repos.isEmpty ? repos : addingRepos ? siblings : [] }
    /// Where the worktrees come from, in the folder's order. The current repo keeps its own checkout, so its branch is the base.
    private var sources: [String] {
        listed.isEmpty ? [directory] : listed.filter(chosen.contains).map { $0 == root ? directory : $0 }
    }
    private var subtitle: String {
        if repos.isEmpty, sources.count < 2 { return "The agent starts in its own worktree, on a new branch from \(base)." }
        return "Each repo you pick gets its own worktree on the same branch, side by side in one folder. The agent starts there and sees them all."
    }

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New task in \(repo)").font(.system(size: 15, weight: .semibold))
                    Text(subtitle)
                        .foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
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
                // Return starts the task. Option-Return adds a line, for longer ones.
                TextField(picked == nil ? "What should the agent do?" : "Anything to add? The agent gets the ticket as it is.",
                          text: $task, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...8)
                    .focused($focus, equals: .task)
                    .sheetField(p, focused: focus == .task)
                    .onChange(of: task) { _, task in
                        if !branchEdited { branch = NewTask.branchName(for: task) }
                    }
                if !listed.isEmpty {
                    repoChecklist(p)
                } else if siblings.count > 1, let root {
                    addReposLink(beside: root, p)
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
                    }
                }
                agentSelect(p)
            }
            .padding(20)
            Rectangle().fill(p.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(SheetButton(palette: p, primary: false))
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    guard let name else { return }
                    let command = choice.command() + " \"$\(NewTask.variable)\""
                    close()
                    // The worktree may fail and show why, which needs this sheet gone first.
                    DispatchQueue.main.async { [sources] in start(name, command, prompt, sources) }
                }
                .buttonStyle(SheetButton(palette: p, primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.isEmpty || name == nil || sources.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .frame(width: 460)
        .background(p.background)
        .ignoresSafeArea()
        .onAppear { focus = .task }
        .task {
            let directory = directory
            // Both at once, since each waits on its own server.
            let board = Jira.Board(line: UserDefaults.standard.string(forKey: Jira.boardKey) ?? "")
            async let jira = Task.detached { (try? Jira.tickets(on: board)) ?? [] }.value
            async let issues = Task.detached { Forge.detect(in: directory)?.issues(in: directory) ?? [] }.value
            let tickets = await jira + issues
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
                SheetChoice(palette: p) { toggle(repo) } label: {
                    Image(systemName: chosen.contains(repo) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(chosen.contains(repo) ? p.text : p.muted)
                    Text(URL(fileURLWithPath: repo).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    // A new branch starts from what the repo has checked out, which is worth seeing when it isn't main.
                    if let branch = branches[repo], !["main", "master"].contains(branch) {
                        Text("from \(branch)").font(.system(size: 11)).foregroundStyle(p.muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
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
    private func addReposLink(beside root: String, _ p: Palette) -> some View {
        let folder = ((root as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return Button {
            chosen = [root]
            addingRepos = true
        } label: {
            Label("Add repos from \(folder)", systemImage: "plus").font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(p.muted)
    }

    /// The mark of where it comes from, its key, then as much of its title as fits on the line.
    private func ticketLabel(_ ticket: Ticket, _ p: Palette) -> some View {
        HStack(spacing: 8) {
            ForgeIcon(source: ticket.source).foregroundStyle(p.muted)
            Text(ticket.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.muted).fixedSize()
            Text(ticket.summary).lineLimit(1).truncationMode(.tail)
        }
    }

    private func agentSelect(_ p: Palette) -> some View {
        SheetSelect(palette: p, open: $pickingAgent) {
            Image(systemName: "terminal").foregroundStyle(p.muted)
            Text(choice.label)
        } choices: {
            VStack(spacing: 1) {
                ForEach(folders, id: \.id) { option in
                    SheetChoice(palette: p) {
                        agent = option.id
                        pickingAgent = false
                    } label: {
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

    private func fill(from ticket: Ticket) {
        picked = ticket
        branch = ticket.branch
        // Counts as your edit, so the branch keeps the ticket's key whatever you type next.
        branchEdited = true
        pickingTicket = false
        query = ""
        focus = .task
    }

    private func dropTicket() {
        picked = nil
        branchEdited = false
        branch = NewTask.branchName(for: task)
        pickingTicket = false
        focus = .task
    }
}
