import AppKit
import FarolCore
import SwiftUI

/// A new pull request: the branch it goes into, read like the forge's form, then its title and description.
/// "Generate" has the agent write both from the branch's commits, as the commit sheet does for a message.
struct RequestSheet: View {
    let request: String
    let forge: String
    let head: String
    let bases: [String]
    /// The checkout the agent reads the commits in.
    let root: String
    let palette: Palette
    /// The names the forge offers as labels. Slow, so it is asked for off the main thread.
    let loadLabels: () -> [String]
    let create: (_ base: String, _ title: String, _ body: String, _ labels: [String]) -> Void
    let close: () -> Void

    private enum Field: Hashable { case title, body }

    @State private var base: String
    @State private var picking = false
    @State private var filter = ""
    @State private var labels: [String] = []
    @State private var chosenLabels: Set<String> = []
    @State private var pickingLabels = false
    @State private var labelFilter = ""
    @State private var title = ""
    @State private var body_ = ""
    @FocusState private var focus: Field?
    /// The same agent choice as the commit sheet, since most people pick one and keep it.
    @AppStorage("commit.agent") private var agent = ""
    @State private var agents = AgentFolder.find().filter { CommitMessage.arguments(for: $0.kind) != nil }
    /// The agent writing, to stop it when the sheet closes.
    @State private var generating: Generation?
    @State private var generationError: String?
    /// What you had typed before the agent wrote over it, until you type again.
    @State private var replaced: (title: String, body: String)?
    @State private var generated: (title: String, body: String)?
    /// What the commits gave for the base now chosen. A field still holding it is replaced when the base changes, one you edited isn't.
    @State private var started: (title: String, body: String) = ("", "")

    init(request: String, forge: String, head: String, bases: [String], preferred: String?, root: String, palette: Palette,
         loadLabels: @escaping () -> [String], create: @escaping (String, String, String, [String]) -> Void,
         close: @escaping () -> Void) {
        self.request = request
        self.forge = forge
        self.head = head
        self.bases = bases
        self.root = root
        self.palette = palette
        self.loadLabels = loadLabels
        self.create = create
        self.close = close
        _base = State(initialValue: preferred.flatMap { bases.contains($0) ? $0 : nil } ?? bases.first ?? "")
    }

    static func present(in window: NSWindow, request: String, forge: String, head: String, bases: [String], preferred: String?,
                        root: String, palette: Palette, loadLabels: @escaping () -> [String],
                        create: @escaping (String, String, String, [String]) -> Void) {
        guard window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        let view = RequestSheet(request: request, forge: forge, head: head, bases: bases, preferred: preferred, root: root,
                                palette: palette, loadLabels: loadLabels, create: create,
                                close: { [weak window, weak sheet] in sheet.map { window?.endSheet($0) } })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }

    private var chosenAgent: AgentFolder? { AgentFolder.choice(agent, in: agents) }

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(title: "Create a \(request)", palette: p) {
                    Text("Opened on \(forge). The title and description start from the branch's commits.")
                }
                HStack(spacing: 10) {
                    // Read with "from" as one line, so it is clear which branch receives and which one is merged.
                    Text("Into").foregroundStyle(p.muted)
                    select(p)
                    Text("from").foregroundStyle(p.muted)
                    // The blue the theme gives a branch to pull, as the forge tints the branch the request comes from.
                    Text(head)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(p.pull)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(p.pull.opacity(0.14)))
                        .layoutPriority(1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Title").foregroundStyle(p.muted)
                    TextField(generating == nil ? "Title" : "\(chosenAgent?.label ?? "The agent") is writing…", text: $title)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .title)
                        .opacity(generating == nil || title.isEmpty ? 1 : 0.45)
                        .disabled(generating != nil)
                        .sheetField(p, focused: focus == .title)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Description").foregroundStyle(p.muted)
                    TextField("Description", text: $body_, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(5...12)
                        .focused($focus, equals: .body)
                        // Room under the text for the button in the corner, so a long description never runs under it.
                        .padding(.bottom, chosenAgent == nil ? 0 : 16)
                        .opacity(generating == nil || body_.isEmpty ? 1 : 0.45)
                        .disabled(generating != nil)
                        .sheetField(p, focused: focus == .body)
                        .overlay(alignment: .bottomTrailing) {
                            if let chosen = chosenAgent {
                                GenerateButton(agent: chosen, agents: agents, running: generating != nil, palette: p,
                                               generate: { generating == nil ? generate(with: chosen) : stop() },
                                               pick: { agent = $0.id })
                                    .disabled(generating == nil && base.isEmpty)
                                    .padding(4)
                            }
                        }
                    hints(p)
                }
                // Only where the forge has labels to offer, so a repo without any shows no empty choice.
                if !labels.isEmpty { labelsRow(p) }
            }
            .padding(20)
            Rectangle().fill(p.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(SheetButton(palette: p, primary: false))
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let (chosen, heading, text) = (base, title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   body_.trimmingCharacters(in: .whitespacesAndNewlines))
                    let picked = labels.filter(chosenLabels.contains)
                    close()
                    // The request is made in the background and may fail with a message of its own, which needs this sheet gone first.
                    DispatchQueue.main.async { create(chosen, heading, text, picked) }
                }
                .buttonStyle(SheetButton(palette: p, primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(base.isEmpty || generating != nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .frame(width: 520)
        .sheetBackground(p)
        .ignoresSafeArea()
        .onAppear {
            focus = .title
            fillFromCommits()
            DispatchQueue.global(qos: .userInitiated).async {
                let names = loadLabels()
                DispatchQueue.main.async { labels = names }
            }
        }
        .onChange(of: base) { _, _ in fillFromCommits() }
        .onDisappear { stop() }
    }

    /// Restore after the agent wrote over something you typed, and what went wrong if it failed.
    private func hints(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let replaced, let generated, title == generated.title, body_ == generated.body {
                Button("Restore") {
                    title = replaced.title
                    body_ = replaced.body
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(p.muted)
                .hoverTip("Put back what you had typed")
            }
            if let generationError {
                Text(generationError)
                    .font(.system(size: 11))
                    .foregroundStyle(p.removed)
                    .lineLimit(2)
                    .hoverTip(generationError)
            }
        }
    }

    /// One select for the labels, with a check on each one taken. It stays open so several can be ticked in a row.
    private func labelsRow(_ p: Palette) -> some View {
        let query = labelFilter.trimmingCharacters(in: .whitespaces)
        let shown = query.isEmpty ? labels : labels.filter { $0.localizedCaseInsensitiveContains(query) }
        let picked = labels.filter(chosenLabels.contains)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Labels").foregroundStyle(p.muted)
            SheetSelect(palette: p, open: $pickingLabels) {
                Image(systemName: "tag").font(.system(size: 12)).foregroundStyle(p.muted)
                Text(picked.isEmpty ? "None" : picked.joined(separator: ", "))
                    .foregroundStyle(picked.isEmpty ? p.muted : p.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } choices: {
                VStack(spacing: 6) {
                    TextField("Filter labels", text: $labelFilter)
                        .textFieldStyle(.plain)
                        .sheetField(p, focused: false)
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(shown, id: \.self) { name in
                                SheetChoice(palette: p) {
                                    if chosenLabels.contains(name) { chosenLabels.remove(name) } else { chosenLabels.insert(name) }
                                } label: {
                                    Text(name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if chosenLabels.contains(name) { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                .padding(6)
                .frame(width: 280)
            }
            .onChange(of: pickingLabels) { _, _ in labelFilter = "" }
        }
    }

    private func fillFromCommits() {
        let (base, head, root) = (base, head, root)
        DispatchQueue.global(qos: .userInitiated).async {
            let text = RequestMessage.fromCommits(head: head, base: base, in: root)
            DispatchQueue.main.async {
                // The base moved on while git answered, or the agent is writing: that answer isn't for these fields anymore.
                guard self.base == base, generating == nil else { return }
                let untouched = title == started.title && body_ == started.body
                started = (text?.title ?? "", text?.body ?? "")
                if untouched, let text {
                    title = text.title
                    body_ = text.body
                }
            }
        }
    }

    /// Writes from the branch's commits against the chosen base, so picking another base first changes what it describes.
    private func generate(with chosen: AgentFolder) {
        let (before, base, head, root) = ((title, body_), base, head, root)
        generationError = nil
        // Set on the click, not once the process runs, so a second click can't start a second agent.
        let run = Generation()
        generating = run
        let started = { (process: Process) in DispatchQueue.main.async { run.process = process } }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try RequestMessage.generate(with: chosen, head: head, base: base, in: root, started: started) }
            DispatchQueue.main.async {
                // Stopped on purpose, or the sheet is gone: nothing to show, and the fields aren't its to write anymore.
                guard !run.stopped else { return }
                generating = nil
                switch result {
                case .success(let text):
                    let typed = !before.0.isEmpty || !before.1.isEmpty
                    replaced = typed ? (before.0, before.1) : nil
                    generated = (text.title, text.body)
                    title = text.title
                    body_ = text.body
                    focus = .title
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

    private var shown: [String] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? bases : bases.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func select(_ p: Palette) -> some View {
        SheetSelect(palette: p, open: $picking) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 12)).foregroundStyle(p.muted)
            // Only as wide as the name, up to a limit, so a short one doesn't leave a gap before the chevron.
            Text(base).lineLimit(1).truncationMode(.middle).frame(maxWidth: 190, alignment: .leading)
        } choices: {
            VStack(spacing: 6) {
                TextField("Filter branches", text: $filter)
                    .textFieldStyle(.plain)
                    .sheetField(p, focused: false)
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(shown, id: \.self) { name in
                            SheetChoice(palette: p) {
                                base = name
                                picking = false
                            } label: {
                                Text(name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if name == base { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            .padding(6)
            .frame(width: 280)
        }
        .fixedSize(horizontal: true, vertical: false)
        .onChange(of: picking) { _, _ in filter = "" }
    }
}
