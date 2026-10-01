import Foundation
import Testing

/// Ghostty skips a color it can't read without a word, so a typo would ship as a hole in the theme.
@Test(arguments: ["Farol Dark", "Farol Light"])
func farolThemeSetsEveryColor(name: String) throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(contentsOf: root.appendingPathComponent("assets/themes/\(name)"), encoding: .utf8)
    let keys = ["background", "foreground", "cursor-color"] + (0..<16).map { "palette = \($0)" }
    for key in keys {
        #expect(text.contains(try Regex("(?m)^\(key) ?= ?#[0-9a-f]{6}$")), "\(name) is missing \(key)")
    }
}
