import AppKit
import FarolCore
import SwiftUI

/// Holds the three column editor and publishes its counts for the bars around it.
final class MergeEditorController: ObservableObject {
    enum Mode: Equatable {
        case loading
        /// Both sides have text, so the three columns show it.
        case text
        /// Deleted on one side, or not text: a choice between whole files.
        case choice(Merge.Conflict.Status, binary: Bool)
        /// A file resolved here, shown as it now is.
        case done(Diff.File)
        /// A file git's rerere resolved like last time, shown against HEAD before you take it.
        case reused(Diff.File)
        /// Nothing selected.
        case empty
    }

    let editor = MergeEditor()
    @Published private(set) var mode = Mode.loading
    @Published private(set) var openDecisions = 0
    @Published private(set) var openChanges = 0
    @Published private(set) var autoCount = 0
    @Published private(set) var conflictCount = 0
    @Published private(set) var warnings: [Merge.Undeclared] = []
    /// The three versions of the file on screen, for previewing a whole-file choice.
    @Published private(set) var versions = Merge.Versions()
    @Published var showAll = false {
        didSet { editor.showAll = showAll }
    }
    private var loaded: String?
    /// Files rerere resolved that you chose to decide again, by rebase step, since the next commit is new ground.
    private var decidingAgain: Set<String> = []
    /// Work on files you left half decided, by path, for the operation step it was done in.
    private var work: [String: MergeEditor.Work] = [:]
    private var workStep: String?

    init() {
        editor.onChange = { [weak self] in self?.count() }
    }

    private func count() {
        openDecisions = editor.openDecisions
        openChanges = editor.openChanges
        autoCount = editor.autoCount
        conflictCount = editor.conflictCount
        warnings = editor.warnings
    }

    /// Reads the selected file's three versions and shows them, unless it is already on screen.
    func load(_ model: MergeModel) {
        // The next commit of a rebase can stop on the same file with new versions, so it is read again.
        if workStep != stepKey(model) { loaded = nil }
        keepWork(model)
        guard let path = model.selected else {
            loaded = nil
            mode = .empty
            return
        }
        guard let status = model.status(of: path) else {
            guard path != loaded || !isDone else { return }
            loaded = path
            mode = .loading
            model.resolvedFile(path) { [weak self] file in
                guard let self, self.loaded == path else { return }
                mode = .done(file)
            }
            return
        }
        guard path != loaded || mode == .empty || isDone else { return }
        loaded = path
        mode = .loading
        if model.reused.contains(path), !decidingAgain.contains(againKey(path, model)) {
            model.resolvedFile(path) { [weak self] file in
                guard let self, self.loaded == path else { return }
                mode = .reused(file)
            }
            return
        }
        model.versions(of: path) { [weak self] versions in
            guard let self, self.loaded == path else { return }
            self.versions = versions
            let binary = [versions.base, versions.mine, versions.other].contains { $0?.contains("\u{0}") == true }
            if model.isTextual(path), !binary, let mine = versions.mine, let other = versions.other {
                let merge = ThreeWay(base: versions.base ?? "", mine: mine, other: other, ignoringWhitespace: model.ignoreWhitespace)
                // Work done on other versions of the file doesn't apply to these.
                let kept = work.removeValue(forKey: path).flatMap { $0.merge == merge ? $0 : $0.carried(to: merge) }
                showAll = kept?.showAll ?? false
                editor.show(path, merge, work: kept)
                count()
                mode = .text
                DispatchQueue.main.async { self.editor.window?.makeFirstResponder(self.editor.textView) }
            } else {
                mode = .choice(status, binary: binary)
            }
        }
    }

    private func againKey(_ path: String, _ model: MergeModel) -> String { "\(model.operation?.step ?? 0):\(path)" }

    private func stepKey(_ model: MergeModel) -> String? {
        model.operation.map { "\(model.root ?? ""):\($0.kind.command):\($0.step ?? 0)" }
    }

    /// Keeps the file on screen as you left it when another one takes its place.
    /// Forgets it once it is resolved, and forgets everything when the operation moves on, since the conflicts are new.
    private func keepWork(_ model: MergeModel) {
        let step = stepKey(model)
        if step != workStep {
            work = [:]
            workStep = step
        } else if mode == .text, let loaded, loaded != model.selected, editor.path == loaded {
            work[loaded] = editor.work
        }
        for path in model.resolved { work[path] = nil }
    }

    /// Opens a file rerere resolved in the three columns, from both sides as git first saw them.
    func decideAgain(_ model: MergeModel) {
        guard let path = loaded else { return }
        decidingAgain.insert(againKey(path, model))
        loaded = nil
        load(model)
    }

    /// Shows the file on screen again from git's versions, as after switching whitespace on or off. Decisions carry over.
    func reload(_ model: MergeModel) {
        guard mode == .text, let path = loaded, editor.path == path else { return }
        work[path] = editor.work
        loaded = nil
        load(model)
    }

    private var isDone: Bool {
        if case .done = mode { true } else { false }
    }

    /// Writes the result and stages it. Only once every change has a decision.
    func markResolved(_ model: MergeModel) {
        if case .reused = mode, let path = loaded { return model.useReused(path, failed: showGitError) }
        guard mode == .text, openDecisions == 0, let path = loaded else { return }
        let summary = MergeModel.Summary(decided: conflictCount, automatic: autoCount, warnings: warnings)
        model.resolve(path, with: editor.result, summary: summary, failed: showGitError)
    }
}

/// Takes the terminal's place while git is stopped on conflicts: the files on the left, the three columns, and the way on.
struct MergePanel: View {
    @ObservedObject var merge: MergeModel
    @ObservedObject var controller: MergeEditorController
    @ObservedObject var state: WindowState
    let close: () -> Void
    /// Runs a command in a new pane under the session's terminal.
    let runInPane: (String) -> Void
    /// Hands a prompt to an agent of the session, or starts one on it.
    let askAgent: (String) -> Void

    @State private var writing = false
    @State private var commitMessage = ""
    @State private var choosingTest = false
    @State private var testCommand = ""

    var body: some View {
        let p = state.palette
        VStack(spacing: 0) {
            header(p)
            Rectangle().fill(p.line).frame(height: 1)
            if merge.steps.count > 1 {
                steps(p)
                Rectangle().fill(p.line).frame(height: 1)
            }
            if merge.operation == nil {
                message("Git isn't stopped on a merge or a rebase here.", p)
            } else {
                HStack(spacing: 0) {
                    if listsFiles {
                        fileList(p).frame(width: 200)
                        Rectangle().fill(p.line).frame(width: 1)
                    }
                    content(p).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // A view wider than its window is centered and spills on both sides. This one can shrink, and stays put on the left.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(p.background)
        .sheet(isPresented: $writing) {
            ContinueSheet(merge: merge, palette: p, message: $commitMessage) {
                merge.proceed(message: commitMessage.trimmingCharacters(in: .whitespacesAndNewlines), failed: showGitError)
            }
        }
        .sheet(isPresented: $choosingTest) {
            TestCommandSheet(palette: p, command: $testCommand) {
                merge.setTestCommand(testCommand.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        .foregroundStyle(p.text)
        .onAppear { controller.load(merge) }
        .onChange(of: merge.selected) { controller.load(merge) }
        .onChange(of: merge.conflicts) { controller.load(merge) }
        .onChange(of: merge.ignoreWhitespace) { controller.reload(merge) }
    }

    // MARK: Header

    private func header(_ p: Palette) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1).truncationMode(.tail) }
            Spacer(minLength: 12)
            if let operation = merge.operation {
                PanelButton(title: "Abort", palette: p) { confirmAbort(operation) }
                if operation.canSkip {
                    PanelButton(title: "Skip This Commit", palette: p) { merge.skip(failed: showGitError) }
                }
                if [.rebase, .am].contains(operation.kind), !merge.hasConflicts {
                    PanelButton(title: "Edit Message…", palette: p) { writeMessage() }.disabled(merge.isBusy)
                }
                PanelButton(title: continueTitle, primary: !merge.hasConflicts, palette: p) { proceed() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(merge.hasConflicts || merge.isBusy)
                    .hoverTip(merge.hasConflicts ? "Resolve every file first" : "Continue (⌘↩)")
            }
            CloseButton(help: "Back to the terminal (esc)", palette: p, action: close)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    /// A merge, a cherry-pick or a revert makes a new commit, so its message is yours to write.
    /// A rebase or `git am` replays commits that already have one, so it goes on straight away unless you ask to edit it.
    private func proceed() {
        if replays { merge.proceed(failed: showGitError) } else { writeMessage() }
    }

    private var replays: Bool { [.rebase, .am].contains(merge.operation?.kind) }

    private func writeMessage() {
        commitMessage = merge.preparedMessage()
        writing = true
    }

    private var continueTitle: String { replays ? "Continue" : "Continue…" }

    private var title: String {
        guard let operation = merge.operation else { return "Conflicts" }
        switch operation.kind {
        case .rebase: return "Rebasing \(operation.mine) onto \(operation.other)"
        case .merge: return "Merging \(operation.other) into \(operation.mine)"
        case .cherryPick: return "Cherry-picking \(operation.other) onto \(operation.mine)"
        case .revert: return "Reverting on \(operation.mine)"
        case .am: return "Applying patches on \(operation.mine)"
        }
    }

    private var detail: String? {
        guard let operation = merge.operation else { return nil }
        let step = operation.step.flatMap { step in operation.total.map { "commit \(step) of \($0)" } }
        let subject = operation.subject.map { "\u{201C}\($0)\u{201D}" }
        let file = listsFiles ? nil : merge.selected.map { ($0 as NSString).lastPathComponent }
        let parts = [file, step, subject].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func confirmAbort(_ operation: Merge.Operation) {
        let alert = NSAlert()
        alert.messageText = operation.kind == .am ? "Stop applying the patches?" : "Abort the \(operation.kind.command)?"
        alert.informativeText = "Everything goes back to how it was before it started. What you resolved here is lost."
        alert.addButton(withTitle: "Abort")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = NSApp.keyWindow else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { merge.abort(failed: showGitError) }
        }
    }

    // MARK: Files

    /// With a single file there is nothing to pick, so the columns get the list's room and the header names the file.
    private var listsFiles: Bool { Set(merge.conflicts.map(\.path)).union(merge.resolved).count > 1 }

    private func fileList(_ p: Palette) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text(merge.hasConflicts
                     ? "\(merge.conflicts.count) in conflict" + (merge.reused.isEmpty ? "" : ", \(merge.reused.count) resolved like last time")
                     : "\(merge.resolved.count) resolved")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(p.muted)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                ForEach(merge.conflicts, id: \.path) { conflict in
                    FileRow(path: conflict.path, resolved: false, reused: merge.reused.contains(conflict.path),
                            edited: merge.hasOutsideEdits(conflict.path), selected: merge.selected == conflict.path, palette: p) {
                        merge.selected = conflict.path
                    }
                }
                ForEach(merge.resolved.filter { path in !merge.conflicts.contains { $0.path == path } }, id: \.self) { path in
                    FileRow(path: path, resolved: true, selected: merge.selected == path, palette: p) { merge.selected = path }
                        .contextMenu {
                            Button("Reopen") { merge.reopen(path, failed: showGitError) }
                        }
                }
            }
            .padding(6)
        }
    }

    /// The rebase's commits in order: replayed, stopped on, still to come.
    private func steps(_ p: Palette) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(merge.steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 { Rectangle().fill(p.line).frame(width: 10, height: 1) }
                        HStack(spacing: 5) {
                            switch step.state {
                            case .done: Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(p.done)
                            case .current: Circle().fill(merge.hasConflicts ? p.waiting : p.done).frame(width: 6, height: 6)
                            case .todo: Circle().strokeBorder(p.muted, lineWidth: 1).frame(width: 6, height: 6)
                            }
                            Text(step.hash).font(.system(size: 11, design: .monospaced))
                            if step.state == .current { Text(step.subject).lineLimit(1) }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(step.state == .todo ? p.muted : p.text)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(step.state == .current ? p.raised : .clear))
                        .hoverTip(step.subject)
                        .id(index)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 30)
            .onAppear { scrollToCurrent(proxy) }
            .onChange(of: merge.steps) { scrollToCurrent(proxy) }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let current = merge.steps.firstIndex(where: { $0.state == .current }) else { return }
        proxy.scrollTo(current, anchor: .center)
    }

    // MARK: Content

    /// A file as it now is against HEAD: resolved here, or by rerere and waiting for you to take it.
    private func resolvedFile(_ file: Diff.File, reused: Bool, _ p: Palette) -> some View {
        VStack(spacing: 0) {
            if !merge.hasConflicts { allResolved(p) }
            HStack(spacing: 8) {
                Image(systemName: reused ? "arrow.counterclockwise" : "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(reused ? p.waiting : p.done)
                Text(reused ? "Resolved like last time" : "Resolved").font(.system(size: 12, weight: .medium))
                Text(file.status == .deleted ? "Deleted" : "Compared with \(headName)").font(.system(size: 12)).foregroundStyle(p.muted)
                Counts(added: file.added, removed: file.removed, palette: p)
                Spacer()
                if let path = merge.selected {
                    if reused {
                        PanelButton(title: "Decide Again", palette: p) { controller.decideAgain(merge) }
                            .hoverTip("Open both sides in the three columns, as git first saw them")
                        PanelButton(title: "Use It", primary: true, palette: p) { merge.useReused(path, failed: showGitError) }
                            .disabled(merge.isBusy)
                            .hoverTip("Git's rerere remembered how you resolved this conflict before. Mark the file resolved this way (⌘S).")
                    } else {
                        PanelButton(title: "Reopen", palette: p) { merge.reopen(path, failed: showGitError) }
                            .disabled(merge.isBusy)
                            .hoverTip("Put this file back in conflict to decide it again")
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            Rectangle().fill(p.line).frame(height: 1)
            if file.hunks.isEmpty {
                message(file.status == .deleted ? "This file is deleted." : "Same as \(headName).", p)
            } else {
                ScrollView {
                    DiffText(file: file, colors: p.diff, syntax: p.code).padding(.vertical, 6).padding(.horizontal, 8)
                }
            }
        }
    }

    @ViewBuilder private func content(_ p: Palette) -> some View {
        switch controller.mode {
        case .loading:
            message("Reading the file…", p)
        case .empty:
            VStack(spacing: 0) {
                if !merge.hasConflicts { allResolved(p) }
                message(merge.hasConflicts ? "Pick a file on the left." : "", p)
            }
        case .done(let file):
            resolvedFile(file, reused: false, p)
        case .reused(let file):
            resolvedFile(file, reused: true, p)
        case .choice(let status, let binary):
            choice(status, binary: binary, p)
        case .text:
            VStack(spacing: 0) {
                if let path = merge.selected, merge.hasOutsideEdits(path) { editedBar(path, p) }
                if let path = merge.selected, let conflict = merge.conflict(path), conflict.modeConflict { modeBar(conflict, p) }
                if let warning = controller.warnings.first { warningBar(warning, p) }
                columnTitles(p)
                Rectangle().fill(p.line).frame(height: 1)
                MergeEditorView(controller: controller, palette: p)
                Rectangle().fill(p.line).frame(height: 1)
                footer(p)
            }
        }
    }

    /// HEAD is the branch the commit lands on: the incoming one during a rebase, yours otherwise.
    private var headName: String {
        guard let operation = merge.operation else { return "HEAD" }
        return operation.kind == .rebase ? operation.other : operation.mine
    }

    /// The file changed on disk after git stopped, which the columns don't show. Taking it as is needs every conflict gone.
    private func editedBar(_ path: String, _ p: Palette) -> some View {
        let left = merge.edited[path] ?? 0
        let marked = left == 1 ? "1 conflict is" : "\(left) conflicts are"
        return HStack(spacing: 8) {
            Image(systemName: "pencil").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.waiting)
            Text("This file changed on disk after git stopped"
                 + (left == 0 ? ", and no conflict is marked in it anymore." : ". \(marked) still marked in it.")
                 + " The columns show git's versions, and Mark Resolved writes over the file.")
                .font(.system(size: 12))
                .foregroundStyle(p.waiting)
                .lineLimit(2)
            Spacer()
            PanelButton(title: "Start From Git's Versions", palette: p) { merge.setEditsAside(path) }
                .hoverTip("Hide this and resolve in the columns. The changes on disk are lost when you mark the file resolved.")
            PanelButton(title: "Use the File on Disk", primary: left == 0, palette: p) { merge.useFileOnDisk(path, failed: showGitError) }
                .disabled(left > 0 || merge.isBusy)
                .hoverTip(left > 0 ? "Remove the conflict markers in the file first, or start from git's versions"
                                   : "Mark the file resolved as it is on disk")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        .background(p.waiting.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 1) }
    }

    /// Both sides changed whether the file is executable. Git left one on disk, and this picks what the result keeps.
    private func modeBar(_ conflict: Merge.Conflict, _ p: Palette) -> some View {
        let onDisk = (merge.operation?.kind == .rebase ? conflict.other : conflict.mine) == .executable
        let executable = merge.executable[conflict.path] ?? onDisk
        let yours = conflict.mine == .executable ? "Yours is executable and incoming isn't." : "Incoming is executable and yours isn't."
        return HStack(spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(p.muted)
            Text("Both sides changed the file mode. \(yours)").font(.system(size: 12)).lineLimit(1)
            Spacer()
            PanelButton(title: "Executable", primary: executable, palette: p) { merge.executable[conflict.path] = true }
            PanelButton(title: "Not Executable", primary: !executable, palette: p) { merge.executable[conflict.path] = false }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 1) }
    }

    /// "DELAY is used on line 11 but no longer declared", with a way to go there.
    private func warningBar(_ warning: Merge.Undeclared, _ p: Palette) -> some View {
        let more = controller.warnings.count - 1
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(p.waiting)
            (Text(warning.name).font(.system(size: 12, design: .monospaced))
                + Text(" is used on line \(warning.line) of the result but no longer declared there")
                + Text(more > 0 ? ", and \(more) more." : "."))
                .font(.system(size: 12))
                .foregroundStyle(p.waiting)
                .lineLimit(1)
            Spacer()
            PanelButton(title: "Show", palette: p) { controller.editor.reveal(resultLine: warning.line) }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(p.waiting.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 1) }
    }

    /// Once every file is resolved: what it took, what may still be wrong, and a way to check before going on.
    private func allResolved(_ p: Palette) -> some View {
        let summaries = merge.summaries
        let files = merge.resolved.count
        let decided = summaries.values.reduce(0) { $0 + $1.decided }
        let automatic = summaries.values.reduce(0) { $0 + $1.automatic }
        let reused = summaries.values.filter(\.reused).count
        let onDisk = summaries.values.filter(\.onDisk).count
        let warnings = summaries.sorted { $0.key < $1.key }.flatMap { path, summary in summary.warnings.map { (path, $0) } }
        let details = [decided > 0 ? "\(decided) by hand" : nil, automatic > 0 ? "\(automatic) auto-merged" : nil,
                       reused > 0 ? "\(reused) like last time" : nil, onDisk > 0 ? "\(onDisk) as edited on disk" : nil]
            .compactMap { $0 }.map { " · " + $0 }.joined()
        // Changes taken on their own can still clash, so the way to check sits next to the count.
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(p.done)
                (Text("\(files) \(files == 1 ? "file" : "files") resolved").fontWeight(.medium)
                    + Text(details).foregroundColor(p.muted))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let command = merge.testCommand {
                    PanelButton(title: "Run \(command)", palette: p) { runInPane(command) }
                        .hoverTip("Run the tests in a new pane under the terminal before you continue")
                    IconButton(symbol: "pencil", help: "Change the test command", palette: p, action: askTestCommand)
                } else {
                    PanelButton(title: "Run Tests…", palette: p) { askTestCommand() }
                        .hoverTip("Choose the command that runs this checkout's tests")
                }
                PanelButton(title: "Ask an Agent…", palette: p) { askAgent(agentPrompt) }
                    .hoverTip("Hand the check to an agent running in this session, or start one on it")
            }
            ForEach(warnings.indices, id: \.self) { index in
                let (path, warning) = warnings[index]
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    Text("\((path as NSString).lastPathComponent): \(warning.name) is used on line \(warning.line) but no longer declared")
                    PanelButton(title: "Open", palette: p) { merge.selected = path }
                }
                .foregroundStyle(p.waiting)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 1) }
    }

    /// Typed into the agent's prompt but not sent, so you can read it first.
    private var agentPrompt: String {
        let kind = merge.operation.map { $0.kind == .am ? "git am" : $0.kind.command } ?? "merge"
        let files = merge.resolved.joined(separator: ", ")
        return "Git stopped on a \(kind) and I resolved the conflicts in \(files). Some changes from both sides were merged "
            + "without a conflict, so they may not fit together. Run the build and the tests, and fix what the merge broke. "
            + "Don't commit and don't continue the \(kind)."
    }

    private func askTestCommand() {
        testCommand = merge.testCommand ?? ""
        choosingTest = true
    }

    /// Each title over its column's code, which the editor lays out.
    private func columnTitles(_ p: Palette) -> some View {
        GeometryReader { geometry in
            let starts = MergeEditor.columnStarts(width: geometry.size.width)
            ZStack(alignment: .leading) {
                label(merge.operation?.mine ?? "", "yours", p.working, p)
                    .frame(width: starts.column, alignment: .leading).offset(x: starts.mine)
                label("Result", "editable", nil, p)
                    .frame(width: starts.column, alignment: .leading).offset(x: starts.center + MergeNumbers.width)
                label(merge.operation?.other ?? "", "incoming", Color(nsColor: p.code.keyword), p)
                    .frame(width: starts.column, alignment: .leading).offset(x: starts.other)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 30)
    }

    /// The dot is the color of the side's bands in the code below.
    private func label(_ name: String, _ role: String, _ color: Color?, _ p: Palette) -> some View {
        HStack(spacing: 6) {
            if let color { Circle().fill(color).frame(width: 6, height: 6) }
            Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(role).font(.system(size: 11)).foregroundStyle(p.muted).lineLimit(1)
        }
        .padding(.leading, 10)
    }

    private func footer(_ p: Palette) -> some View {
        // On a narrow window the two whole-file buttons go first. They stay in the menu and on their shortcuts.
        ViewThatFits(in: .horizontal) {
            footerRow(p, wholeFile: true)
            footerRow(p, wholeFile: false)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background {
            Group {
                Button("") { controller.editor.acceptAll(mine: true) }
                    .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
                Button("") { controller.editor.acceptAll(mine: false) }
                    .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
            }
            .opacity(0)
        }
    }

    private func footerRow(_ p: Palette, wholeFile: Bool) -> some View {
        let left = controller.openDecisions
        return HStack(spacing: 6) {
            Text(left == 0 ? "Everything decided" : "\(controller.openChanges) \(controller.openChanges == 1 ? "change" : "changes") to decide")
                .foregroundStyle(p.muted)
                .lineLimit(1)
                .padding(.trailing, 4)
            Group {
                IconButton(symbol: "chevron.up", help: "Previous change to decide (⌥↑)", palette: p) {
                    controller.editor.jump(forward: false)
                }
                IconButton(symbol: "chevron.down", help: "Next change to decide (⌥↓)", palette: p) {
                    controller.editor.jump(forward: true)
                }
            }
            .disabled(left == 0)
            .opacity(left == 0 ? 0.45 : 1)
            Spacer(minLength: 8)
            if wholeFile {
                PanelButton(title: "Accept Yours", palette: p) { controller.editor.acceptAll(mine: true) }
                    .hoverTip("Fill the result with your side (⌃⌘←)")
                PanelButton(title: "Accept Incoming", palette: p) { controller.editor.acceptAll(mine: false) }
                    .hoverTip("Fill the result with the incoming side (⌃⌘→)")
            }
            IconButton(symbol: "ellipsis", help: "More", active: controller.showAll || merge.ignoreWhitespace, palette: p,
                       action: showOptions)
            PanelButton(title: "Mark Resolved", primary: left == 0, palette: p) { controller.markResolved(merge) }
                .disabled(left > 0 || merge.isBusy)
                .hoverTip(left > 0 ? "Decide every change first" : "Mark the file resolved (⌘S)")
        }
    }

    private func showOptions() {
        let menu = NSMenu()
        func add(_ title: String, on: Bool = false, arrow: Int? = nil, _ run: @escaping () -> Void) {
            let item = ActionMenuItem(title: title, handler: run)
            item.state = on ? .on : .off
            if let arrow, let key = UnicodeScalar(arrow) {
                item.keyEquivalent = String(key)
                item.keyEquivalentModifierMask = [.control, .command]
            }
            menu.addItem(item)
        }
        add("Accept Yours for the Whole File", arrow: NSLeftArrowFunctionKey) { controller.editor.acceptAll(mine: true) }
        add("Accept Incoming for the Whole File", arrow: NSRightArrowFunctionKey) { controller.editor.acceptAll(mine: false) }
        menu.addItem(.separator())
        add("Show All Lines", on: controller.showAll) { controller.showAll.toggle() }
        // Settles conflicts where a side only changed spacing or indentation. Decisions are kept.
        add("Ignore Whitespace", on: merge.ignoreWhitespace) { merge.ignoreWhitespace.toggle() }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func choice(_ status: Merge.Conflict.Status, binary: Bool, _ p: Palette) -> some View {
        let path = merge.selected ?? ""
        let versions = controller.versions
        let other = merge.operation?.other ?? "the other side"
        // Same rule as the columns: yours on the left with ⌃⌘←, the incoming side on the right with ⌃⌘→.
        func accept(mine: Bool, keeps: Bool) -> ChoiceView.Option {
            // The side taken, or the other one when that side deleted the file.
            let kept = mine ? versions.mine ?? versions.other : versions.other ?? versions.mine
            return .init(title: mine ? "Accept Yours" : "Accept Incoming", effect: keeps ? "Keeps the file" : "Deletes the file",
                         result: keeps ? kept : nil,
                         shortcut: mine ? .leftArrow : .rightArrow,
                         apply: keeps ? { merge.keep(path, failed: showGitError) } : { merge.delete(path, failed: showGitError) })
        }
        let text: String
        var options: [ChoiceView.Option] = []
        switch status {
        case .deletedByOther:
            text = "\(other) deleted this file, and you changed it."
            options = [accept(mine: true, keeps: true), accept(mine: false, keeps: false)]
        case .deletedByMine:
            text = "You deleted this file, and \(other) changed it."
            options = [accept(mine: true, keeps: false), accept(mine: false, keeps: true)]
        case .bothDeleted:
            text = "Both sides deleted this file."
            options = [.init(title: "Accept the Deletion", effect: "Deletes the file", result: nil, shortcut: .leftArrow,
                             apply: { merge.delete(path, failed: showGitError) })]
        case .addedByMine:
            text = "Only you have this file, often after a rename on the other side."
            options = [accept(mine: true, keeps: true), accept(mine: false, keeps: false)]
        case .addedByOther:
            text = "Only \(other) has this file, often after a rename on your side."
            options = [accept(mine: true, keeps: false), accept(mine: false, keeps: true)]
        case .bothModified, .bothAdded:
            text = binary ? "Both sides changed this file, and it isn't text." : whole(merge.conflict(path))
            options = [.init(title: "Accept Yours", effect: "Your version", result: versions.mine, shortcut: .leftArrow,
                             apply: { merge.take(mine: true, path, failed: showGitError) }),
                       .init(title: "Accept Incoming", effect: "The incoming version", result: versions.other, shortcut: .rightArrow,
                             apply: { merge.take(mine: false, path, failed: showGitError) })]
        }
        return ChoiceView(path: path, explanation: text, base: versions.base, binary: binary, options: options,
                          busy: merge.isBusy, palette: p)
            .id(path)
    }

    /// Why a file both sides changed is a choice between whole sides rather than text to merge.
    private func whole(_ conflict: Merge.Conflict?) -> String {
        guard let conflict else { return "Both sides changed this file." }
        let entries = [conflict.mine, conflict.other]
        if entries.allSatisfy({ $0 == .submodule }) { return "Both sides moved this submodule, each to its own commit." }
        if entries.allSatisfy({ $0 == .symlink }) { return "Both sides changed where this link points." }
        if entries.contains(.submodule) || entries.contains(.symlink) {
            let thing: (Merge.Conflict.Entry?) -> String = { $0 == .submodule ? "a submodule" : $0 == .symlink ? "a link" : "a file" }
            return "You have \(thing(conflict.mine)) here, and \(merge.operation?.other ?? "the other side") has \(thing(conflict.other))."
        }
        if conflict.sameContent {
            return conflict.mine == .executable ? "Both sides have the same content, but only yours is executable."
                : "Both sides have the same content, but only the incoming one is executable."
        }
        return "Both sides changed this file."
    }

    private func message(_ text: String, _ p: Palette) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(p.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A whole-file decision: pick an option, read the file it leaves against the common ancestor, then apply it.
private struct ChoiceView: View {
    struct Option {
        let title: String
        /// What it does to the file, in a few words.
        let effect: String
        /// The file's text afterwards. Nil when it ends up deleted.
        let result: String?
        /// With ⌃⌘, applies the option straight away, like Accept Yours and Accept Incoming in the three columns.
        var shortcut: KeyEquivalent?
        let apply: () -> Void
    }

    let path: String
    let explanation: String
    let base: String?
    let binary: Bool
    let options: [Option]
    let busy: Bool
    let palette: Palette

    @State private var picked = 0

    var body: some View {
        let p = palette
        let option = options[min(picked, options.count - 1)]
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text((path as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                Text(explanation).font(.system(size: 12)).foregroundStyle(p.muted)
            }
            HStack(spacing: 8) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    OptionCard(title: option.title + (option.shortcut.map { " ⌃⌘" + ($0 == .leftArrow ? "←" : "→") } ?? ""),
                               detail: detail(option), selected: index == picked, palette: p) {
                        picked = index
                    }
                    .background {
                        if let shortcut = option.shortcut {
                            Button("", action: option.apply)
                                .keyboardShortcut(shortcut, modifiers: [.control, .command])
                                .disabled(busy)
                                .opacity(0)
                        }
                    }
                }
            }
            Text(option.result == nil ? "Result: the file is deleted" : "Result, compared with the common ancestor")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(p.muted)
            Group {
                if binary {
                    Text("This file isn't text, so there is nothing to preview.").font(.system(size: 12)).foregroundStyle(p.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        DiffText(file: Merge.preview(path, from: base, to: option.result), colors: p.diff, syntax: p.code)
                            .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(p.background))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.line))
            HStack {
                Spacer()
                PanelButton(title: option.title,
                            primary: true, palette: p, action: option.apply)
                    .disabled(busy)
            }
        }
        .padding(16)
    }

    /// "Keeps the file, +1 −0 against the ancestor", so each option says what it does before you look.
    private func detail(_ option: Option) -> String {
        if binary { return option.effect + (option.result.map { ", \($0.utf8.count) bytes" } ?? "") }
        let file = Merge.preview(path, from: base, to: option.result)
        if option.result == nil { return "\(option.effect), \(file.removed) \(file.removed == 1 ? "line" : "lines")" }
        return "\(option.effect), +\(file.added) −\(file.removed) against the ancestor"
    }
}

private struct OptionCard: View {
    let title: String
    let detail: String
    let selected: Bool
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12)).foregroundStyle(selected ? palette.text : palette.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(palette.muted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? palette.raised : hovering ? palette.surface : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? palette.muted : palette.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onClickableHover { hovering = $0 }
    }
}

private struct FileRow: View {
    let path: String
    let resolved: Bool
    var reused = false
    var edited = false
    let selected: Bool
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if resolved {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.done).frame(width: 8)
                } else if reused {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.waiting)
                        .frame(width: 8)
                        .hoverTip("Resolved like last time, waiting for you to look")
                } else if edited {
                    Image(systemName: "pencil").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.waiting)
                        .frame(width: 8)
                        .hoverTip("Changed on disk after git stopped")
                } else {
                    Circle().fill(palette.waiting).frame(width: 7, height: 7).frame(width: 8)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text((path as NSString).lastPathComponent).font(.system(size: 12.5))
                        .foregroundStyle(resolved ? palette.muted : palette.text)
                    let folder = (path as NSString).deletingLastPathComponent
                    if !folder.isEmpty { Text(folder).font(.system(size: 11)).foregroundStyle(palette.muted) }
                }
                .lineLimit(1)
                .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? palette.selection : hovering ? palette.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onClickableHover { hovering = $0 }
    }
}

private struct PanelButton: View {
    let title: String
    var primary = false
    let palette: Palette
    let action: () -> Void

    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(primary ? palette.background : palette.text)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(primary ? palette.text : hovering ? palette.raised : palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? .clear : palette.line))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onClickableHover { hovering = $0 }
    }
}

private struct MergeEditorView: NSViewRepresentable {
    let controller: MergeEditorController
    let palette: Palette

    func makeNSView(context: Context) -> MergeEditor { controller.editor }

    func updateNSView(_ view: MergeEditor, context: Context) {
        view.apply(colors: MergeColors(palette), syntax: palette.code)
    }
}

/// Git's own message, under a title saying what didn't happen.
private func showGitError(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
}

/// The command that runs this checkout's tests. Farol remembers it per checkout.
private struct TestCommandSheet: View {
    let palette: Palette
    @Binding var command: String
    let save: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool

    private var ready: Bool { !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Test command").font(.system(size: 15, weight: .semibold))
                    Text("It runs in a new pane under the terminal. Farol remembers it for this checkout.")
                        .foregroundStyle(p.muted)
                }
                TextField("make test", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($typing)
                    .sheetField(p, focused: typing)
            }
            .padding(20)
            Rectangle().fill(p.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SheetButton(palette: p, primary: false))
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    dismiss()
                    save()
                }
                .buttonStyle(SheetButton(palette: p, primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .frame(width: 460)
        .background(p.background)
        .onAppear { typing = true }
    }
}

/// The message of the commit Continue makes, starting from the one git prepared.
private struct ContinueSheet: View {
    @ObservedObject var merge: MergeModel
    let palette: Palette
    @Binding var message: String
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool

    private var ready: Bool { !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var title: String {
        switch merge.operation?.kind {
        case .rebase: "Continue the rebase"
        case .am: "Continue applying patches"
        case .cherryPick: "Commit the cherry-pick"
        case .revert: "Commit the revert"
        default: "Commit the merge"
        }
    }

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if !merge.resolved.isEmpty {
                        Text("Resolved: " + merge.resolved.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                            .foregroundStyle(p.muted)
                            .lineLimit(2)
                    }
                }
                // Return confirms. Option-Return adds a line, for a body under the subject.
                TextField("Commit message", text: $message, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...12)
                    .focused($typing)
                    .sheetField(p, focused: typing)
            }
            .padding(20)
            Rectangle().fill(p.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SheetButton(palette: p, primary: false))
                    .keyboardShortcut(.cancelAction)
                Button([.rebase, .am].contains(merge.operation?.kind) ? "Continue" : "Commit") {
                    dismiss()
                    confirm()
                }
                .buttonStyle(SheetButton(palette: p, primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .frame(width: 460)
        .background(p.background)
        .onAppear { typing = true }
    }
}
