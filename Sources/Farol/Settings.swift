import AppKit

/// The settings page edits a few keys in ~/.config/farol/config (Ghostty config syntax).
/// Any other line in that file is kept as is, so power users can add anything Ghostty supports.
final class Settings: ObservableObject {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/farol/config")

    @Published var theme: String { didSet { write("theme", theme) } }
    @Published var fontFamily: String { didSet { write("font-family", fontFamily) } }
    @Published var fontSize: Int { didSet { write("font-size", String(fontSize)) } }
    @Published var cursorStyle: String { didSet { write("cursor-style", cursorStyle) } }

    /// Called after every change so the terminal can reload.
    var onChange: (() -> Void)?

    private var lines: [String]

    init() {
        lines = (try? String(contentsOf: Self.fileURL, encoding: .utf8))?
            .components(separatedBy: "\n") ?? []
        let values = Self.parse(lines)
        theme = values["theme"] ?? ""
        fontFamily = values["font-family"] ?? ""
        fontSize = values["font-size"].flatMap { Int($0) } ?? 13
        cursorStyle = values["cursor-style"] ?? "block"
    }

    /// Empty value removes the key, falling back to the Ghostty default.
    private func write(_ key: String, _ value: String) {
        let index = lines.firstIndex { Self.key(of: $0) == key }
        switch (index, value.isEmpty) {
        case let (i?, true): lines.remove(at: i)
        case let (i?, false): lines[i] = "\(key) = \(value)"
        case (nil, false): lines.insert("\(key) = \(value)", at: 0)
        case (nil, true): return
        }

        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A trailing newline, so a line appended with `echo >>` stays its own line.
        let text = lines.filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
        try? text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
        onChange?()
    }

    func openFile() {
        if !FileManager.default.fileExists(atPath: Self.fileURL.path) { write("cursor-style", cursorStyle) }
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
