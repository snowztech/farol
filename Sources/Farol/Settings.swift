import AppKit

/// The settings page edits a few keys in ~/.config/farol/config (Ghostty config syntax).
/// Any other line in that file is kept as is, so power users can add anything Ghostty supports.
final class Settings: ObservableObject {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/farol/config")

    @Published var theme = "" { didSet { write("theme", theme) } }
    @Published var fontFamily = "" { didSet { write("font-family", fontFamily) } }
    @Published var fontSize = 13 { didSet { write("font-size", String(fontSize)) } }
    @Published var cursorStyle = "block" { didSet { write("cursor-style", cursorStyle) } }
    /// Ghostty blinks by default, so only "off" is written.
    @Published var cursorBlink = true { didSet { write("cursor-style-blink", cursorBlink ? "" : "false") } }
    /// "false", "left", "right" or "true". Off keeps Option for typing accents.
    @Published var optionAsAlt = "false" { didSet { write("macos-option-as-alt", optionAsAlt == "false" ? "" : optionAsAlt) } }
    /// Selecting text copies it to the clipboard right away.
    @Published var copyOnSelect = false { didSet { write("copy-on-select", copyOnSelect ? "clipboard" : "") } }

    /// Called after every change, from the page or from the file, so the terminal can reload.
    var onChange: (() -> Void)?

    /// Set while values come from the file, so they are not written straight back.
    private var loading = false
    /// What Farol last wrote, to tell its own saves from yours.
    private var lastWritten: String?
    private var watcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?

    init() {
        reload()
        watch()
    }

    private static func read() -> [String] {
        var lines = ((try? String(contentsOf: fileURL, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Reads the file again. Also runs on Reload Configuration.
    func reload() {
        loading = true
        defer { loading = false }
        let values = Self.parse(Self.read())
        theme = values["theme"] ?? ""
        fontFamily = values["font-family"] ?? ""
        fontSize = values["font-size"].flatMap { Int($0) } ?? 13
        cursorStyle = values["cursor-style"] ?? "block"
        cursorBlink = values["cursor-style-blink"] != "false"
        optionAsAlt = values["macos-option-as-alt"] ?? "false"
        copyOnSelect = values["copy-on-select"] == "clipboard"
    }

    /// Editors save by replacing the file, which only the folder reports.
    /// Tools like cp and >> write into the file in place, which only the file reports. So both are watched.
    private func watch() {
        let folder = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watcher = source(for: folder.path) { [weak self] in
            // A replaced file is a new file, so the old watch no longer sees it.
            self?.watchFile()
            self?.fileChanged()
        }
        watchFile()
    }

    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = source(for: Self.fileURL.path) { [weak self] in self?.fileChanged() }
    }

    private func source(for path: String, handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func fileChanged() {
        let text = try? String(contentsOf: Self.fileURL, encoding: .utf8)
        guard text != lastWritten else { return }
        lastWritten = text
        reload()
        onChange?()
    }

    /// Changes one line and keeps everything else in the file as you wrote it. An empty value removes the key.
    private func write(_ key: String, _ value: String) {
        guard !loading else { return }
        var lines = Self.read()
        if lines.isEmpty { lines = Self.template }
        let index = lines.firstIndex { Self.key(of: $0) == key }
        switch (index, value.isEmpty) {
        case let (i?, true): lines.remove(at: i)
        case let (i?, false): lines[i] = "\(key) = \(value)"
        case (nil, false): lines.append("\(key) = \(value)")
        case (nil, true): return
        }
        save(lines)
        onChange?()
    }

    private func save(_ lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n"
        lastWritten = text
        try? text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }

    private static let template = [
        "# Farol settings. Save this file and the change applies right away.",
        "# The settings page writes here too, so use whichever you like.",
        "# Every option is listed at https://ghostty.org/docs/config",
        "",
    ]

    func openFile() {
        if Self.read().isEmpty { save(Self.template) }
        NSWorkspace.shared.open(Self.fileURL)
    }

    private static func key(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { return nil }
        return trimmed[..<eq].trimmingCharacters(in: .whitespaces)
    }

    private static func parse(_ lines: [String]) -> [String: String] {
        var values: [String: String] = [:]
        for line in lines {
            guard let key = key(of: line), let eq = line.firstIndex(of: "=") else { continue }
            values[key] = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return values
    }

    static let monospacedFamilies: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        return Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }()
}
