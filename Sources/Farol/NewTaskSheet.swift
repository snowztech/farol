import AppKit
import FarolCore
import SwiftUI

/// The New Task sheet: what to do, on which branch, with which agent.
struct NewTaskSheet: View {
    private enum Field { case task, branch }

    let repo: String
    let base: String
    let palette: Palette
    /// Gets a valid branch and the command that launches the agent.
    let start: (String, String) -> Void
    let close: () -> Void

    @AppStorage("newTask.agent") private var agent = NewTask.Agent.claude.rawValue
    @State private var task = ""
    @State private var branch = ""
    /// The branch follows the task until you edit it yourself.
    @State private var branchEdited = false
    @FocusState private var focus: Field?

    static func present(in window: NSWindow, directory: String, palette: Palette, start: @escaping (String, String) -> Void) {
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        let view = NewTaskSheet(
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
    private var name: String? { Worktrees.branchName(from: branch) }
    private var choice: NewTask.Agent { NewTask.Agent(rawValue: agent) ?? .claude }

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
                // Return starts the task. Option-Return adds a line, for longer ones.
                TextField("What should the agent do?", text: $task, axis: .vertical)
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
                HStack(spacing: 6) {
                    ForEach(NewTask.Agent.allCases, id: \.self) { option in
                        SheetOption(title: option.title, selected: choice == option, palette: p) { agent = option.rawValue }
                    }
                }
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
                    let command = NewTask.command(choice, task: text)
                    close()
                    // The worktree may fail and show why, which needs this sheet gone first.
                    DispatchQueue.main.async { start(name, command) }
                }
                .buttonStyle(SheetButton(palette: p, primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(text.isEmpty || name == nil)
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
    }
}
