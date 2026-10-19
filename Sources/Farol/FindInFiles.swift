import FarolCore
import SwiftUI

/// ⇧⌘F: every line with the text typed, in the files under the folder of the pane you are in. Return opens one at its line.
struct FindInFiles: View {
    /// Where the search starts, the focused pane's folder.
    let folder: String
    let palette: Palette
    let open: (String, Int) -> Void

    @State private var query = ""
    @State private var matches: [FileSearch.Match] = []
    @State private var searching = false
    /// The row the arrows or the mouse are on. Without one, Return opens the first match.
    @State private var active: FileSearch.Match?
    @State private var listHeight: CGFloat = 0
    /// Each search counts up, so the answer of one typed over is dropped.
    @State private var generation = 0
    @FocusState private var focused: Bool

    private static let limit = 300

    var body: some View {
        let p = palette
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(p.muted)
                TextField("Find in \((folder as NSString).abbreviatingWithTildeInPath)", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { highlighted.map(choose) }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                if searching { ProgressView().controlSize(.small) }
                Text("⇧⌘F").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
            }
            .padding(12)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Rectangle().fill(p.line).frame(height: 1)
                results(p)
            }
        }
        .frame(width: 560)
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .background(p.boxed ? p.surface : p.background)
        .onAppear { focused = true }
        .onChange(of: query) { _, query in search(query) }
    }

    private func results(_ p: Palette) -> some View {
        let files = grouped
        return ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(files, id: \.path) { file in
                        FileHeader(path: file.path, count: file.matches.count, palette: p)
                        ForEach(file.matches, id: \.self) { match in
                            MatchRow(match: match, query: query, lit: highlighted == match, palette: p,
                                     hover: { inside in
                                         if inside { active = match } else if active == match { active = nil }
                                     },
                                     choose: { choose(match) })
                            .id(match)
                        }
                    }
                    if files.isEmpty && !searching {
                        Text("Nothing matches.").foregroundStyle(p.muted).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    if matches.count == Self.limit {
                        Text("The first \(Self.limit) matches. Type more to narrow it down.")
                            .font(.system(size: 11)).foregroundStyle(p.muted).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            // An exact height, since the popover only follows its rows when it has no other choice.
            .frame(height: min(listHeight, 420))
            .onChange(of: active) { _, row in if let row { scroll.scrollTo(row) } }
        }
    }

    /// In the order git or the walk found them, a header per file.
    private var grouped: [(path: String, matches: [FileSearch.Match])] {
        var files: [(path: String, matches: [FileSearch.Match])] = []
        for match in matches {
            if files.last?.path == match.path { files[files.count - 1].matches.append(match) } else { files.append((match.path, [match])) }
        }
        return files
    }

    private var highlighted: FileSearch.Match? { matches.first { $0 == active } ?? matches.first }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .handled }
        let index = highlighted.flatMap(matches.firstIndex) ?? 0
        active = matches[(index + step + matches.count) % matches.count]
        return .handled
    }

    /// A moment after the last key, off the main thread, since a big checkout takes a while to read.
    private func search(_ query: String) {
        generation += 1
        let current = generation
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            (matches, active, searching) = ([], nil, false)
            return
        }
        searching = true
        let folder = folder
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard current == generation else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let found = FileSearch.search(query, in: folder, limit: Self.limit)
                DispatchQueue.main.async {
                    guard current == generation else { return }
                    (matches, active, searching) = (found, nil, false)
                }
            }
        }
    }

    private func choose(_ match: FileSearch.Match) {
        open(folder + "/" + match.path, match.line)
    }
}

/// A file's name, the folder it is in, and how many of its lines match.
private struct FileHeader: View {
    let path: String
    let count: Int
    let palette: Palette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(palette.muted)
            Text((path as NSString).lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text((path as NSString).deletingLastPathComponent)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted)
        }
        .padding(.horizontal, 9)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// One matching line: its number, then the line with the text found in bold.
private struct MatchRow: View {
    let match: FileSearch.Match
    let query: String
    /// Under the arrows or the mouse.
    let lit: Bool
    let palette: Palette
    let hover: (Bool) -> Void
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Text("\(match.line)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted)
                    .frame(width: 40, alignment: .trailing)
                Text(marked).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(lit ? palette.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietPress())
        .onClickableHover(hover)
    }

    /// The line in muted text with every match in the text color, so the eye finds it in a long line.
    private var marked: AttributedString {
        var text = AttributedString(match.text)
        text.foregroundColor = palette.muted
        var rest = match.text.startIndex..<match.text.endIndex
        while let found = match.text.range(of: query, options: .caseInsensitive, range: rest) {
            if let range = Range(found, in: text) {
                text[range].foregroundColor = palette.text
                text[range].font = .system(size: 12, weight: .bold, design: .monospaced)
            }
            rest = found.upperBound..<match.text.endIndex
        }
        return text
    }
}
