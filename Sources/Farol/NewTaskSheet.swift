import AppKit
import FarolCore
import SwiftUI

/// The New Task sheet: what to do, on which branch, with which agent.
struct NewTaskSheet: View {
    private enum Field { case task, branch }

    let directory: String
    let repo: String
    let base: String
    let palette: Palette
    /// Gets a valid branch and the command that launches the agent.
    let start: (String, String) -> Void
    let close: () -> Void

    @AppStorage("newTask.agent") private var agent = AgentFolder.Kind.claude.rawValue
    /// Every Claude Code and Codex config folder found, so each account is a choice.
    @State private var folders = AgentFolder.find()
    @State private var task = ""
    @State private var branch = ""
    /// The branch follows the task until you edit it yourself.
    @State private var branchEdited = false
    @FocusState private var focus: Field?
    /// Your open Jira tickets and the repo's open GitHub issues. Empty until they load, and without the tools that list them.
    @State private var tickets: [Ticket] = []
    @State private var picked: Ticket?
    @State private var pickingTicket = false
    @State private var pickingAgent = false
    @State private var query = ""
    @FocusState private var searching: Bool

    static func present(in window: NSWindow, directory: String, palette: Palette, start: @escaping (String, String) -> Void) {
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        let view = NewTaskSheet(
            directory: directory,
            repo: Git.repoRoot(of: directory).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "repository",
            base: Git.branch(of: directory) ?? "the current commit",
            palette: palette, start: start,
            close: { [weak window, weak sheet] in sheet.map { window?.endSheet($0) } })
        let host = NSHostingController(rootView: view)
        // The sheet grows with the task as it wraps onto more lines.
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }

    private var text: String { task.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The picked ticket in full, which the sheet doesn't show, then what you typed.
    private var prompt: String {
        [picked?.task ?? "", text].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    private var name: String? { Worktrees.branchName(from: branch) }
    private var choice: AgentFolder { AgentFolder.choice(agent, in: folders) ?? folders[0] }

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New task in \(repo)").font(.system(size: 15, weight: .semibold))
                    Text("The agent starts in its own worktree, on a new branch from \(base).")
                        .foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !tickets.isEmpty { ticketSelect(p) }
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
                    let command = choice.command(task: prompt)
                    close()
                    // The worktree may fail and show why, which needs this sheet gone first.
                    DispatchQueue.main.async { start(name, command) }
                }
                .buttonStyle(SheetButton(palette: p, primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.isEmpty || name == nil)
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
            tickets = await jira + issues
        }
    }

    private var matches: [Ticket] {
        let words = query.lowercased().split(separator: " ")
        return tickets.filter { ticket in
            let text = "\(ticket.key) \(ticket.summary)".lowercased()
            return words.allSatisfy(text.contains)
        }
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
