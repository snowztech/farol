import FarolCore
import SwiftUI

/// What Find in Files searched and found. Kept by the window, so going back to the tree or closing the panel keeps the search.
final class FindInFilesModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { search() } }
    }
    @Published var caseSensitive = UserDefaults.standard.bool(forKey: "files.search.caseSensitive") {
        didSet { optionChanged(caseSensitive, "files.search.caseSensitive") }
    }
    @Published var wholeWord = UserDefaults.standard.bool(forKey: "files.search.wholeWord") {
        didSet { optionChanged(wholeWord, "files.search.wholeWord") }
    }
    @Published var regex = UserDefaults.standard.bool(forKey: "files.search.regex") {
        didSet { optionChanged(regex, "files.search.regex") }
    }
    /// From the repo's top instead of the pane's folder.
    @Published var wholeRepo = UserDefaults.standard.bool(forKey: "files.search.wholeRepo") {
        didSet { optionChanged(wholeRepo, "files.search.wholeRepo") }
    }
    /// Globs typed in the files field, like `*.swift, !*Tests*`.
    @Published var globs = "" {
        didSet { if globs != oldValue { search() } }
    }
    @Published var showsFiles = false
    @Published private(set) var matches: [FileSearch.Match] = []
    @Published private(set) var searching = false
    /// The row the arrows or the mouse are on. Without one, Return opens the first match.
    @Published var active: FileSearch.Match?
    /// The folder the matches are in, so a pane that moved since still opens the right file.
    private(set) var searched = ""

    /// Read when a search runs, since the focused pane can change while the panel is open.
    var paneFolder: () -> String? = { nil }
    var repoFolder: () -> String? = { nil }

    /// Where a search starts: the pane's folder, or its repo's top.
    func folder() -> String? { wholeRepo ? repoFolder() ?? paneFolder() : paneFolder() }

    /// The repo's top is a choice only below it, where it searches more than the folder does.
    var canWiden: Bool { repoFolder().map { $0 != paneFolder() } ?? false }

    /// While the panel shows the search. Files that change under it then search again, so the lines stay true after an agent's edit.
    var live = false {
        didSet { if live != oldValue { watch() } }
    }
    private var watcher: FolderWatcher?
    private var refresh: DispatchWorkItem?

    static let limit = 300
    private var pending: DispatchWorkItem?
    private var job: FileSearch.Job?

    var options: FileSearch.Options {
        FileSearch.Options(caseSensitive: caseSensitive, wholeWord: wholeWord, regex: regex, files: FileSearch.Options.files(from: globs))
    }
    var invalid: Bool { !FileSearch.isValid(query, options: options) }
    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func optionChanged(_ on: Bool, _ key: String) {
        UserDefaults.standard.set(on, forKey: key)
        search()
    }

    /// A moment after the last key, off the main thread. The search before is stopped, git grep and all.
    func search() {
        pending?.cancel()
        job?.cancel()
        guard hasQuery, !invalid, let folder = folder() else {
            (matches, active, searching) = ([], nil, false)
            return
        }
        searching = true
        let (query, options, job) = (query, options, FileSearch.Job())
        self.job = job
        let work = DispatchWorkItem {
            DispatchQueue.global(qos: .userInitiated).async {
                let found = FileSearch.search(query, in: folder, options: options, limit: Self.limit, job: job)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.job === job, !job.isCancelled else { return }
                    // A search run again after an edit keeps your place when the line is still there.
                    let kept = active.flatMap { old in found.first { $0.path == old.path && $0.line == old.line } }
                    let moved = searched != folder
                    (matches, searched, active, searching) = (found, folder, kept, false)
                    if moved { watch() }
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func watch() {
        watcher = nil
        guard live, !searched.isEmpty else { return }
        watcher = FolderWatcher(searched, latency: 0.5) { [weak self] paths in
            // Git touches .git at every prompt, which changes no file's lines.
            guard let self, paths.contains(where: { !$0.contains("/.git/") }) else { return }
            refresh?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.search() }
            refresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    var highlighted: FileSearch.Match? { matches.first { $0 == active } ?? matches.first }

    /// The match after or before the one you are on, for F4 and ⇧F4 from the file. Wraps around.
    func step(_ by: Int) -> FileSearch.Match? {
        guard !matches.isEmpty else { return nil }
        if let active, let index = matches.firstIndex(of: active) {
            self.active = matches[(index + by + matches.count) % matches.count]
        } else {
            self.active = by > 0 ? matches.first : matches.last
        }
        return self.active
    }

    func move(_ step: Int) {
        guard !matches.isEmpty else { return }
        let index = highlighted.flatMap(matches.firstIndex) ?? 0
        active = matches[(index + step + matches.count) % matches.count]
    }

    /// In the order git or the walk found them, a header per file.
    var files: [(path: String, matches: [FileSearch.Match])] {
        var files: [(path: String, matches: [FileSearch.Match])] = []
        for match in matches {
            if files.last?.path == match.path { files[files.count - 1].matches.append(match) } else { files.append((match.path, [match])) }
        }
        return files
    }
}

/// The files panel in search mode, from ⇧⌘F or its magnifier: every line with the text typed, in the files under the focused pane's folder.
/// Return or a click opens one at its line.
struct FindInFiles: View {
    @ObservedObject var model: FindInFilesModel
    @ObservedObject var state: WindowState
    let open: (String, Int) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        let p = state.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(p.muted)
                TextField("Find in \(((model.folder() ?? "") as NSString).lastPathComponent)", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .onSubmit { model.highlighted.map(choose) }
                    .onKeyPress(.downArrow) {
                        model.move(1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        model.move(-1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        state.filesSearching = false
                        return .handled
                    }
                if model.searching { ProgressView().controlSize(.mini) }
                OptionToggle(label: Text("Aa"), help: "Match case", on: $model.caseSensitive, palette: p)
                OptionToggle(label: Text("ab").underline(), help: "Whole word", on: $model.wholeWord, palette: p)
                OptionToggle(label: Text(".*"), help: "Regular expression", on: $model.regex, palette: p)
                OptionToggle(label: Image(systemName: "line.3.horizontal.decrease"), help: "Files to search",
                             on: $model.showsFiles, palette: p)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(p.raised))
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 4)
            if model.showsFiles { filesField(p) }
            if model.canWiden { scope(p) }
            if let summary {
                HStack(spacing: 0) {
                    note(summary, p)
                    Spacer(minLength: 0)
                    IconButton(symbol: "arrow.clockwise", help: "Search again", palette: p) { model.search() }
                }
                .padding(.horizontal, 6)
            }
            results(p)
        }
        .onAppear { focused = true }
        // ⇧⌘F again, with the panel already searching, puts the cursor back in the field.
        .onChange(of: state.filesSearchFocus) { _, _ in focused = true }
    }

    private func filesField(_ p: Palette) -> some View {
        TextField("Files, like *.swift, !*Tests*", text: $model.globs)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .onKeyPress(.escape) {
                state.filesSearching = false
                return .handled
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(p.raised))
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }

    /// The pane's folder or its whole repo, like two tabs.
    private func scope(_ p: Palette) -> some View {
        HStack(spacing: 4) {
            ScopeButton(title: ((model.paneFolder() ?? "") as NSString).lastPathComponent, on: !model.wholeRepo, palette: p) {
                model.wholeRepo = false
            }
            ScopeButton(title: "Whole repo", on: model.wholeRepo, palette: p) { model.wholeRepo = true }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    /// How much was found, so a cut at the limit is never silent.
    private var summary: String? {
        guard model.hasQuery, !model.invalid, !model.matches.isEmpty else { return nil }
        let lines = model.matches.count, files = model.files.count
        let count = lines == FindInFilesModel.limit ? "First \(lines)" : "\(lines)"
        return "\(count) \(lines == 1 ? "result" : "results") in \(files) \(files == 1 ? "file" : "files")"
    }

    private func results(_ p: Palette) -> some View {
        let files = model.files
        // Wide enough for the longest number, so line 1000 shows whole and every row lines up.
        let digits = String(model.matches.map(\.line).max() ?? 0).count
        return ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(files, id: \.path) { file in
                        FileHeader(path: file.path, count: file.matches.count, palette: p)
                        ForEach(file.matches, id: \.self) { match in
                            MatchRow(match: match, query: model.query, options: model.options, digits: digits, lit: model.highlighted == match, palette: p,
                                     hover: { inside in
                                         if inside { model.active = match } else if model.active == match { model.active = nil }
                                     },
                                     choose: { choose(match) })
                            .id(match)
                        }
                        if file.matches.count == FileSearch.perFile {
                            note("Only the first \(FileSearch.perFile) lines of this file.", p).padding(.leading, CGFloat(max(digits, 3)) * 6.5 + 12)
                        }
                    }
                    if model.invalid {
                        note("This regular expression isn't valid.", p)
                    } else if files.isEmpty && !model.searching && model.hasQuery {
                        note("Nothing matches.", p)
                    }
                    if model.matches.count == FindInFilesModel.limit {
                        note("Type more to narrow it down.", p)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .onChange(of: model.active) { _, row in if let row { scroll.scrollTo(row) } }
        }
    }

    private func note(_ text: String, _ p: Palette) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(p.muted).padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func choose(_ match: FileSearch.Match) {
        open(model.searched + "/" + match.path, match.line)
    }
}

/// A file's name, the folder it is in, and how many of its lines match.
private struct FileHeader: View {
    let path: String
    let count: Int
    let palette: Palette

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(palette.muted).frame(width: 14)
            Text((path as NSString).lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1).layoutPriority(1)
            Text((path as NSString).deletingLastPathComponent)
                .font(.system(size: 10.5)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            Text(verbatim: String(count)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.muted)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// One matching line: its number, then the line from just before the match, with the match in bold.
private struct MatchRow: View {
    let match: FileSearch.Match
    let query: String
    let options: FileSearch.Options
    /// Of the longest line number in the list.
    let digits: Int
    /// Under the arrows or the mouse.
    let lit: Bool
    let palette: Palette
    let hover: (Bool) -> Void
    let choose: () -> Void

    /// The panel is narrow, so a match far into a long line would be cut off. The line starts a few characters before it.
    private static let lead = 12

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 6) {
                Text(verbatim: String(match.line))
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.muted)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: CGFloat(max(digits, 3)) * 6.5 + 2, alignment: .trailing)
                Text(marked).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(lit ? palette.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietPress())
        .onClickableHover(hover)
    }

    /// The line in muted text with every match in the text color, so the eye finds it.
    private var marked: AttributedString {
        var line = match.text
        if let first = FileSearch.ranges(of: query, in: line, options: options).first,
           line.distance(from: line.startIndex, to: first.lowerBound) > Self.lead {
            line = "…" + line[line.index(first.lowerBound, offsetBy: -Self.lead)...]
        }
        var text = AttributedString(line)
        text.foregroundColor = palette.muted
        for found in FileSearch.ranges(of: query, in: line, options: options) {
            guard let range = Range(found, in: text) else { continue }
            text[range].foregroundColor = palette.text
            text[range].font = .system(size: 11.5, weight: .bold, design: .monospaced)
        }
        return text
    }
}

/// A search option in the field, lit while on.
private struct OptionToggle<Label: View>: View {
    let label: Label
    let help: String
    @Binding var on: Bool
    let palette: Palette

    @State private var hovering = false

    var body: some View {
        Button { on.toggle() } label: {
            label
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(on ? palette.text : hovering ? palette.text : palette.muted)
                .frame(width: 20, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? palette.selection : .clear))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? palette.muted.opacity(0.6) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietPress())
        .onClickableHover { hovering = $0 }
        .hoverTip(help)
    }
}

/// One of the two places a search starts from.
private struct ScopeButton: View {
    let title: String
    let on: Bool
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .foregroundStyle(on || hovering ? palette.text : palette.muted)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? palette.selection : hovering ? palette.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietPress())
        .onClickableHover { hovering = $0 }
    }
}
