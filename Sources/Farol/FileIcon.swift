import FarolCore
import CoreText
import Foundation
import SwiftUI

/// What kind of file a path is, so a list of files reads at a glance. Drawn in gray, since color means agent status.
struct FileIcon: View {
    let path: String
    var folder = false

    var body: some View {
        if let glyph = Self.glyph(for: path, folder: folder) {
            // Seti's marks are drawn small in their square, so this size reads like a symbol beside it.
            // They take a symbol's room whatever frame they sit in, and a wide one, like Go's, spills past it rather than shrinking.
            Text(verbatim: glyph).font(.custom("seti", size: 18)).fixedSize().frame(width: 15, height: 14)
        } else {
            Image(systemName: Self.symbol(for: path, folder: folder))
        }
    }

    /// Called once at launch. Info.plist's ATSApplicationFontsPath doesn't load the WOFF file, so it's registered here.
    static func registerFont() {
        guard let url = Bundle.main.url(forResource: "seti", withExtension: "woff", subdirectory: "fonts") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// The language's mark in the Seti font that VS Code uses, bundled in the app. SF Symbols has one for Swift and no other language.
    private static func glyph(for path: String, folder: Bool = false) -> String? {
        if folder || path.hasSuffix("/") { return nil }
        return seti[((path as NSString).pathExtension).lowercased()]
    }

    private static let seti: [String: String] = [
        "c": "\u{E00C}", "h": "\u{E00C}", "m": "\u{E00C}", "mm": "\u{E00C}",
        "cc": "\u{E01A}", "cpp": "\u{E01A}", "hpp": "\u{E01A}",
        "cs": "\u{E00B}",
        "css": "\u{E01D}", "scss": "\u{E084}",
        "dart": "\u{E021}",
        "ex": "\u{E028}", "exs": "\u{E028}",
        "go": "\u{E03A}",
        "htm": "\u{E048}", "html": "\u{E048}",
        "java": "\u{E050}",
        "js": "\u{E051}", "mjs": "\u{E051}", "cjs": "\u{E051}",
        "jsx": "\u{E07D}", "tsx": "\u{E07D}",
        "kt": "\u{E058}", "kts": "\u{E058}",
        "lua": "\u{E05E}",
        "php": "\u{E070}",
        "prisma": "\u{E075}",
        "py": "\u{E07B}",
        "rb": "\u{E081}",
        "rs": "\u{E082}",
        "scala": "\u{E086}",
        "sql": "\u{E022}",
        "svelte": "\u{E090}",
        "swift": "\u{E092}",
        "ts": "\u{E099}",
        "vue": "\u{E09D}",
        "zig": "\u{E0A8}",
    ]

    private static func symbol(for path: String, folder: Bool = false) -> String {
        if folder || path.hasSuffix("/") { return "folder" }
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.hasPrefix(".env") { return "key" }
        if name.hasSuffix(".lock") || name.hasSuffix("-lock.json") || name.hasSuffix(".resolved") { return "lock" }
        if ["makefile", "dockerfile", "justfile", "rakefile"].contains(name) { return "hammer" }
        switch (name as NSString).pathExtension {
        case "md", "markdown", "mdx", "txt", "rst": return "doc.text"
        case "json", "jsonc", "yml", "yaml", "toml", "ini", "conf", "plist": return "curlybraces"
        case "sh", "bash", "zsh", "fish": return "terminal"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "ico", "icns": return "photo"
        case "mp4", "mov", "webm": return "film"
        case "mp3", "wav", "m4a", "aiff": return "waveform"
        case "zip", "gz", "tgz", "tar", "dmg": return "doc.zipper"
        case "csv", "tsv": return "tablecells"
        case "pdf": return "doc.richtext"
        default: return Syntax.language(for: path) == nil ? "doc" : "chevron.left.forwardslash.chevron.right"
        }
    }
}
