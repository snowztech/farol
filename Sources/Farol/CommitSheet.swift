import AppKit
import FarolCore
import SwiftUI

/// How far a commit goes. The last choice is remembered.
enum AfterCommit: String {
    case nothing, push, openRequest
}

/// "Commit" in the review panel. Opens the sheet, then commits the uncommitted changes you left ticked.
/// "Changes since main" offers it too, since that is where a branch's review usually sits.
struct CommitButton: View {
    @ObservedObject var review: ReviewModel
    let palette: Palette

    var body: some View {
        let left = review.excluded.count, taken = review.uncommitted - left
        // With every file unticked there is nothing to commit, so the button waits for a tick.
        ShipButton(title: review.isShipping ? "Committing…" : left == 0 || taken == 0 ? "Commit" : "Commit \(taken) of \(review.uncommitted)",
                   help: taken == 0 ? "Tick a file to commit it"
                       : (left == 0 ? "Commit the uncommitted changes" : "Commit the files you left ticked") + " (⌥⌘C)",
                   busy: review.isShipping || taken == 0, keys: "⌥⌘C", palette: palette) { review.askCommit() }
    }
}

extension View {
    /// The commit sheet, on the panel itself so ⌥⌘C opens it whatever the panel is showing.
    func commitSheet(_ review: ReviewModel, palette: Palette) -> some View {
        modifier(CommitSheetHost(review: review, palette: palette))
    }
}

private struct CommitSheetHost: ViewModifier {
    @ObservedObject var review: ReviewModel
    let palette: Palette

    /// Kept here, so a commit that a hook refuses doesn't cost you the message.
    @State private var message = ""

    func body(content: Content) -> some View {
        content.sheet(isPresented: $review.askingCommit) {
            CommitSheet(review: review, palette: palette, message: $message) { next, paths in
                review.ship(message: message.trimmingCharacters(in: .whitespacesAndNewlines), only: paths, then: next,
                            failed: gitFailure)
            }
        }
    }
}

/// Shown once there is nothing left to commit.
/// "Create PR" when the forge's tool says there is none yet: pushes the branch and creates it, titled from the commits.
/// Without the tool Farol can't tell or create, so it says "Pull Request" and opens the forge's page after the push.
struct RequestButton: View {
    @ObservedObject var review: ReviewModel
    let palette: Palette

    var body: some View {
        if let forge = review.forge, let branch = review.branch {
            let create = review.canCreateRequest
            ShipButton(title: review.isShipping ? "Pushing…" : create ? "Create \(forge.requestShort)" : forge.request.capitalized,
                       help: create ? "Push \(branch) and create a \(forge.request) on \(forge.name), titled from its commits"
                           : "Push \(branch) and open its \(forge.request) page on \(forge.name). Install \(forge.tool) to create it from here.",
                       busy: review.isShipping, icon: forge.kind, palette: palette) {
                review.ship(message: nil, then: .openRequest, failed: gitFailure)
            }
        }
    }
}

/// Shown after a commit that wasn't pushed, where there is no request to create. A new change brings "Commit" back.
struct PushButton: View {
    @ObservedObject var review: ReviewModel
    let palette: Palette

    var body: some View {
        let count = review.unpushed
        ShipButton(title: review.isShipping ? "Pushing…" : "Push",
                   help: "Push \(count) commit\(count == 1 ? "" : "s")\(review.branch.map { " on \($0)" } ?? "") (⌥⌘P)",
                   busy: review.isShipping, keys: "⌥⌘P", palette: palette) { review.push() }
    }
}

extension ReviewModel {
    /// Pushes while the Push button is the next step, from the button or ⌥⌘P.
    func push() {
        guard canPush, !isShipping else { return NSSound.beep() }
        ship(message: nil, then: .push, failed: gitFailure)
    }
}

/// "PR #5", once the branch has an open request. Opens it in the browser. Its checks sit before it, once it has some.
struct RequestBadge: View {
    @ObservedObject var review: ReviewModel
    let palette: Palette

    var body: some View {
        if let forge = review.forge, case .open(let number, let url) = review.request {
            if !review.checks.isEmpty { ChecksButton(checks: review.checks, palette: palette) }
            ShipButton(title: "\(forge.requestShort) #\(number)", help: "View \(forge.request) #\(number) on \(forge.name)",
                       busy: false, icon: forge.kind, palette: palette) { NSWorkspace.shared.open(url) }
        }
    }
}

/// How the request's pipeline is doing. Click it for the steps, each opening its own page.
private struct ChecksButton: View {
    let checks: [Forge.Check]
    let palette: Palette

    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            // They come with what needs you first, so the first says how the whole pipeline is doing.
            CheckMark(state: checks[0].state, palette: palette)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering || open ? palette.raised : palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onClickableHover { hovering = $0 }
        .hoverTip(summary)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 1) {
                ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                    SheetChoice(palette: palette) {
                        if let url = check.url { NSWorkspace.shared.open(url) }
                        open = false
                    } label: {
                        CheckMark(state: check.state, palette: palette)
                        Text(check.name).lineLimit(1)
                    }
                }
            }
            .padding(6)
            .frame(minWidth: 220)
            .font(.system(size: 12))
            .foregroundStyle(palette.text)
            .background(palette.background)
        }
    }

    private var summary: String {
        let count = { (state: Forge.Check.State) in checks.filter { $0.state == state }.count }
        if count(.failed) > 0 { return "\(count(.failed)) of \(checks.count) checks failed" }
        if count(.running) > 0 { return "\(count(.running)) of \(checks.count) checks still running" }
        return "Checks passed"
    }
}

private struct CheckMark: View {
    let state: Forge.Check.State
    let palette: Palette

    var body: some View {
        let (symbol, color) = switch state {
        case .failed: ("xmark.circle.fill", palette.removed)
        case .running: ("clock.fill", palette.waiting)
        case .passed: ("checkmark.circle.fill", palette.added)
        case .skipped: ("minus.circle", palette.muted)
        }
        Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(color)
    }
}

/// Git's own message, which carries what a hook printed or why the push was refused.
private func gitFailure(_ title: String, _ info: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = info
    if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
}

/// The quiet bordered button of the review panel, also used at the end of a settings row.
struct ShipButton: View {
    let title: String
    var help: String? = nil
    let busy: Bool
    /// The forge's mark before the title, on the buttons that send you there.
    var icon: Forge.Kind? = nil
    /// The shortcut that does the same, shown after the title.
    var keys: String? = nil
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        if let help { button.hoverTip(help) } else { button }
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { ForgeIcon(kind: icon) }
                Text(title).font(.system(size: 12, weight: .medium))
                if let keys { Text(keys).font(.system(size: 11)).foregroundStyle(palette.muted) }
            }
            .foregroundStyle(busy ? palette.muted : palette.text)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? palette.raised : palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onClickableHover { hovering = $0 }
    }
}

/// One run of the agent, kept from the click so it can be stopped before its process has started.
private final class Generation {
    var process: Process? { didSet { if stopped { process?.terminate() } } }
    private(set) var stopped = false

    func stop() {
        stopped = true
        process?.terminate()
    }
}

/// "Generate" with a wand in the message field's corner, and an arrow to pick the agent or account.
/// Quiet like the toolbar's icon buttons, since most people pick an agent once: its name is in the tooltip and the menu.
private struct GenerateButton: View {
    let agent: AgentFolder
    let agents: [AgentFolder]
    /// While the agent writes, the wand turns into a spinner and a click stops it.
    let running: Bool
    let palette: Palette
    let generate: () -> Void
    let pick: (AgentFolder) -> Void

    @Environment(\.isEnabled) private var enabled
    @State private var hoveringGenerate = false
    @State private var hoveringPicker = false

    var body: some View {
        HStack(spacing: 1) {
            Button(action: generate) {
                HStack(spacing: 4) {
                    if running {
                        ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 11, height: 11)
                    } else {
                        Image(systemName: "wand.and.rays").font(.system(size: 10.5, weight: .medium))
                    }
                    Text(running ? "Stop" : "Generate").font(.system(size: 11.5, weight: .medium))
                }
                .padding(.horizontal, 6)
                .frame(height: 20)
                .foregroundStyle(hoveringGenerate && enabled ? palette.text : palette.muted)
                .background(RoundedRectangle(cornerRadius: 6).fill(hoveringGenerate && enabled ? palette.raised : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onClickableHover { hoveringGenerate = $0 }
            .hoverTip(running ? "Stop \(agent.label)" : "Generate with \(agent.label)")
            if agents.count > 1, !running {
                Menu {
                    ForEach(agents, id: \.id) { folder in
                        Button { pick(folder) } label: {
                            if folder == agent { Label(folder.label, systemImage: "checkmark") } else { Text(folder.label) }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .frame(width: 14, height: 20)
                        .foregroundStyle(hoveringPicker ? palette.text : palette.muted)
                        .background(RoundedRectangle(cornerRadius: 6).fill(hoveringPicker ? palette.raised : .clear))
                        .contentShape(Rectangle())
                }
                // Plain keeps the label as drawn here. The bordered styles put AppKit's own, larger arrow in.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .onClickableHover { hoveringPicker = $0 }
                .hoverTip("Choose the agent")
            }
        }
        .opacity(enabled ? 1 : 0.4)
    }
}

/// The box that says whether a file goes in the next commit, in the review panel and in the commit sheet.
struct Tick: View {
    let on: Bool
    let palette: Palette

    /// Drawn like the rest of the chrome: a soft box with a thin edge, and only the check mark in the text color.
    var body: some View {
        RoundedRectangle(cornerRadius: 3.5)
            .fill(on ? palette.raised : .clear)
            .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(palette.muted.opacity(on ? 0.35 : 0.6)))
            .overlay {
                if on { Image(systemName: "checkmark").font(.system(size: 7.5, weight: .bold)).foregroundStyle(palette.text) }
            }
            .frame(width: 13, height: 13)
    }
}

/// The branch, the files that go in, the message, and how far to take it.
private struct CommitSheet: View {
    @ObservedObject var review: ReviewModel
    let palette: Palette
    @Binding var message: String
    /// Gets the paths to commit, or nil when every file goes in.
    let confirm: (AfterCommit, [String]?) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("review.afterCommit") private var remembered = AfterCommit.nothing.rawValue
    @State private var files: [Diff.File]?
    @FocusState private var typing: Bool
    @AppStorage("commit.agent") private var agent = ""
    @State private var agents = AgentFolder.find()
    /// The agent writing the message, to stop it when the sheet closes.
    @State private var generating: Generation?
    @State private var generationError: String?
    /// What you had typed before the agent wrote over it, until you type again.
    @State private var replaced: String?
    @State private var generated: String?

    /// The remembered choice, unless it makes no sense here, as when the branch already has a pull request.
    private var next: AfterCommit {
        let choice = AfterCommit(rawValue: remembered) ?? .nothing
        return choice == .openRequest && !review.canStartRequest ? .push : choice
    }

    /// Files unticked here or in the panel. They stay uncommitted in the working tree.
    private var excluded: Set<String> { review.excluded }
    private var chosen: [Diff.File] { (files ?? []).filter { !excluded.contains($0.path) } }

    private var ready: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (files == nil || !chosen.isEmpty)
    }

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Commit changes").font(.system(size: 15, weight: .semibold))
                    if let branch = review.branch {
                        Label(branch, systemImage: "arrow.triangle.branch").foregroundStyle(p.muted)
                    }
                }
                changes(p)
                // Return confirms. Option-Return adds a line, for a body under the subject.
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Commit message", text: $message, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(3...8)
                        .focused($typing)
                        // Room under the text for the button in the corner, so a long message never runs under it.
                        .padding(.bottom, chosenAgent == nil ? 0 : 16)
                        .opacity(generating == nil ? 1 : 0.45)
                        .disabled(generating != nil)
                        .sheetField(p, focused: typing)
                        .overlay(alignment: .bottomTrailing) {
                            if let chosen = chosenAgent {
                                GenerateButton(agent: chosen, agents: agents, running: generating != nil, palette: p,
                                               generate: { generating == nil ? generate(with: chosen) : stop() },
                                               pick: { agent = $0.id })
                                    .disabled(generating == nil && files != nil && self.chosen.isEmpty)
                                    .padding(4)
                            }
                        }
                    hints(p)
                }
                VStack(spacing: 6) {
                    option(.nothing, "Commit", p)
                    option(.push, "Commit and push", p)
                    if let forge = review.forge, review.canStartRequest {
                        option(.openRequest, "Commit, push and \(review.canCreateRequest ? "create" : "start") a \(forge.request) on \(forge.name)", p)
                    }
                }
            }
            .padding(20)
            Rectangle().fill(p.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SheetButton(palette: p, primary: false))
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    let next = next
                    // A renamed file is two paths to git: the one it left and the one it has now.
                    let paths = excluded.isEmpty ? nil : chosen.flatMap { [$0.oldPath, $0.path].compactMap { $0 } }
                    dismiss()
                    confirm(next, paths)
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
        .onAppear {
            typing = true
            review.uncommittedFiles { files = $0 }
        }
        .onDisappear { stop() }
    }

    private var chosenAgent: AgentFolder? { AgentFolder.choice(agent, in: agents) }

    /// "⌥↩ for a new line", Restore after the agent wrote over a message, and what went wrong if it failed.
    private func hints(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("⌥↩ for a new line")
                if let replaced, message == generated {
                    Button("Restore") { message = replaced }
                        .buttonStyle(.plain)
                        .hoverTip("Put back what you had typed")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(p.muted)
            if let generationError {
                Text(generationError)
                    .font(.system(size: 11))
                    .foregroundStyle(p.removed)
                    .lineLimit(2)
                    .hoverTip(generationError)
            }
        }
    }

    /// Describes the ticked files, or every file when none is left out, like the commit itself.
    private func generate(with chosen: AgentFolder) {
        guard let root = review.root else { return }
        let paths = excluded.isEmpty ? nil : self.chosen.flatMap { [$0.oldPath, $0.path].compactMap { $0 } }
        let before = message
        generationError = nil
        // Set on the click, not once the process runs, so a second click can't start a second agent.
        let run = Generation()
        generating = run
        let started = { (process: Process) in DispatchQueue.main.async { run.process = process } }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CommitMessage.generate(with: chosen, paths: paths, in: root, started: started) }
            DispatchQueue.main.async {
                // Stopped on purpose, or the sheet is gone: nothing to show, and the message isn't its to write anymore.
                guard !run.stopped else { return }
                generating = nil
                switch result {
                case .success(let text):
                    replaced = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : before
                    generated = text
                    message = text
                    typing = true
                case .failure(let error):
                    generationError = String(describing: error)
                }
            }
        }
    }

    private func stop() {
        generating?.stop()
        generating = nil
    }

    private var confirmTitle: String {
        switch next {
        case .nothing: "Commit"
        case .push: "Commit and Push"
        case .openRequest: "Commit and \(review.canCreateRequest ? "Create" : "Start") \(review.forge?.requestShort ?? "PR")"
        }
    }

    /// "5 files +821 −61", then each file. The ticked ones go in, staged or not, and they all start ticked.
    private func changes(_ p: Palette) -> some View {
        let files = files ?? [], chosen = chosen
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                review.excludeAll(excluded.isEmpty)
            } label: {
                HStack(spacing: 8) {
                    if self.files != nil, review.canChooseFiles { Tick(on: excluded.isEmpty, palette: p) }
                    Text(excluded.isEmpty ? "\(review.uncommitted) \(review.uncommitted == 1 ? "file" : "files")"
                         : "\(chosen.count) of \(files.count) files")
                    if self.files != nil {
                        Counts(added: chosen.reduce(0) { $0 + $1.added }, removed: chosen.reduce(0) { $0 + $1.removed }, palette: p)
                    }
                    Spacer()
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverTip(excluded.isEmpty ? "Leave every file out" : "Take every file")
            .allowsHitTesting(review.canChooseFiles)
            if !files.isEmpty {
                Rectangle().fill(p.line).frame(height: 1)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(files, id: \.path) { file in
                            let taken = !excluded.contains(file.path)
                            Button {
                                review.toggleExcluded(file.path)
                            } label: {
                                HStack(spacing: 8) {
                                    if review.canChooseFiles { Tick(on: taken, palette: p) }
                                    (Text((file.path as NSString).lastPathComponent).foregroundColor(taken ? p.text : p.muted)
                                        + Text("  " + (file.path as NSString).deletingLastPathComponent).foregroundColor(p.muted))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Counts(added: file.added, removed: file.removed, palette: p).opacity(taken ? 1 : 0.4)
                                }
                                .font(.system(size: 12))
                                .padding(.horizontal, 12)
                                .frame(height: 24)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .allowsHitTesting(review.canChooseFiles)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // Five rows show, more scroll, so a big change doesn't push the message off the screen.
                .frame(height: min(CGFloat(files.count), 5) * 24 + 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.line))
    }

    private func option(_ step: AfterCommit, _ title: String, _ p: Palette) -> some View {
        SheetOption(title: title, selected: next == step, palette: p) { remembered = step.rawValue }
    }
}
