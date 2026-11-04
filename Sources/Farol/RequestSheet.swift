import AppKit
import SwiftUI

/// Where a new pull request goes, read like the forge's own form: the branch it goes into, then the one it comes from.
struct RequestSheet: View {
    let request: String
    let forge: String
    let head: String
    let bases: [String]
    let palette: Palette
    let create: (String) -> Void
    let close: () -> Void

    @State private var base: String
    @State private var picking = false
    @State private var filter = ""

    init(request: String, forge: String, head: String, bases: [String], preferred: String?, palette: Palette,
         create: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.request = request
        self.forge = forge
        self.head = head
        self.bases = bases
        self.palette = palette
        self.create = create
        self.close = close
        _base = State(initialValue: preferred.flatMap { bases.contains($0) ? $0 : nil } ?? bases.first ?? "")
    }

    static func present(in window: NSWindow, request: String, forge: String, head: String, bases: [String], preferred: String?,
                        palette: Palette, create: @escaping (String) -> Void) {
        guard window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        let view = RequestSheet(request: request, forge: forge, head: head, bases: bases, preferred: preferred, palette: palette,
                                create: create, close: { [weak window, weak sheet] in sheet.map { window?.endSheet($0) } })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(title: "Create a \(request)", palette: p) {
                    Text("Opened on \(forge) and titled from the branch's commits.")
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
            }
            .padding(20)
            Rectangle().fill(p.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(SheetButton(palette: p, primary: false))
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let chosen = base
                    close()
                    // The request is made in the background and may fail with a message of its own, which needs this sheet gone first.
                    DispatchQueue.main.async { create(chosen) }
                }
                .buttonStyle(SheetButton(palette: p, primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(base.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .frame(width: 520)
        .sheetBackground(p)
        .ignoresSafeArea()
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
