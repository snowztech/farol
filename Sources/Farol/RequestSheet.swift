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
    /// Gets nil once the request is made, or what went wrong.
    let create: (_ base: String, _ title: String, _ body: String, _ labels: [String], _ draft: Bool, _ done: @escaping (String?) -> Void) -> Void
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
    @State private var creating = false
    @AppStorage("request.draft") private var draft = false
    @State private var createError: String?

    init(request: String, forge: String, head: String, bases: [String], preferred: String?, root: String, palette: Palette,
         loadLabels: @escaping () -> [String], create: @escaping (String, String, String, [String], Bool, @escaping (String?) -> Void) -> Void,
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
                        create: @escaping (String, String, String, [String], Bool, @escaping (String?) -> Void) -> Void) {
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
                // Laid out like the commit sheet: the branch under the title, then plain fields with no captions over them.
                SheetHeader(title: "New \(request)", palette: p) {
                    Label(head, systemImage: "arrow.triangle.branch")
                }
                select(p)
                VStack(alignment: .leading, spacing: 10) {
                    TextField(generating == nil ? "Title" : "\(chosenAgent?.label ?? "The agent") is writing…", text: $title)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .title)
                        .opacity(generating == nil || title.isEmpty ? 1 : 0.45)
                        .disabled(generating != nil)
                        .sheetField(p, focused: focus == .title)
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
                Toggle("Draft", isOn: $draft)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(p.muted)
                    .hoverTip("Open it as a draft, not ready for review yet")
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(SheetButton(palette: p, primary: false))
                    .keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : "Create \(request.capitalized)") {
                    creating = true
                    createError = nil
                    // Open until the forge answers, so a failure leaves the title and description here to try again.
                    create(base, heading, body_.trimmingCharacters(in: .whitespacesAndNewlines), labels.filter(chosenLabels.contains), draft) { error in
                        creating = false
                        if let error { createError = error } else { close() }
                    }
                }
                .buttonStyle(SheetButton(palette: p, primary: true))
                .keyboardShortcut(.defaultAction)
                // Without a title the tool fills one from the commits and drops the description.
                .disabled(base.isEmpty || heading.isEmpty || generating != nil || creating)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .frame(width: 460)
        .sheetBackground(p)
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

    /// The width of the select it opens from, so the list reads as that field opened up.
    private static let listWidth: CGFloat = 420

    private var heading: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

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
            if let error = createError ?? generationError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(p.removed)
                    .lineLimit(2)
                    .hoverTip(error)
            }
        }
    }

    /// One select for the labels, with a check on each one taken. It stays open so several can be ticked in a row.
    private func labelsRow(_ p: Palette) -> some View {
        let query = labelFilter.trimmingCharacters(in: .whitespaces)
        let shown = query.isEmpty ? labels : labels.filter { $0.localizedCaseInsensitiveContains(query) }
        let picked = labels.filter(chosenLabels.contains)
        return SheetSelect(palette: p, open: $pickingLabels) {
            Image(systemName: "tag").font(.system(size: 12)).foregroundStyle(p.muted)
            Text(picked.isEmpty ? "No labels" : picked.joined(separator: ", "))
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
                                    .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                                if chosenLabels.contains(name) { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            .padding(6)
            .frame(width: Self.listWidth)
        }
        .onChange(of: pickingLabels) { _, _ in labelFilter = "" }
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
            Text("Into \(Text(base).foregroundStyle(p.text))").foregroundStyle(p.muted).lineLimit(1).truncationMode(.middle)
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
                                // The name takes the row's room, so the check sits at its right edge.
                                Text(name).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                                if name == base { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            .padding(6)
            .frame(width: Self.listWidth)
        }
        .onChange(of: picking) { _, _ in filter = "" }
    }
}
