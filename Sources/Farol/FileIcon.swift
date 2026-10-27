import Foundation
import SwiftUI

/// What kind of file a path is, so a list of files reads at a glance. Drawn in gray, since color means agent status.
/// SF Symbols has a logo for Swift and for no other language, so code shows its extension, like `go` or `php`, rather than one shape for all of them.
struct FileIcon: View {
    let path: String
    var folder = false

    var body: some View {
        if let symbol = Self.symbol(for: path, folder: folder) {
            Image(systemName: symbol)
        } else {
            // Sized like the symbols, and as wide as it needs, the way an image ignores the frame it sits in.
            Text(verbatim: Self.fileExtension(path))
                .font(.system(size: 8, weight: .semibold).width(.condensed))
                .fixedSize()
        }
    }

    /// nil when the file's extension says more than a symbol would.
    static func symbol(for path: String, folder: Bool = false) -> String? {
        if folder || path.hasSuffix("/") { return "folder" }
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.hasPrefix(".env") { return "key" }
        if name.hasSuffix(".lock") || name.hasSuffix("-lock.json") || name.hasSuffix(".resolved") { return "lock" }
        if ["makefile", "dockerfile", "justfile", "rakefile"].contains(name) { return "hammer" }
        switch fileExtension(path) {
        case "md", "markdown", "mdx", "txt", "rst": return "doc.text"
        case "json", "jsonc", "yml", "yaml", "toml", "ini", "conf", "plist": return "curlybraces"
        case "sh", "bash", "zsh", "fish": return "terminal"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "ico", "icns": return "photo"
        case "mp4", "mov", "webm": return "film"
        case "mp3", "wav", "m4a", "aiff": return "waveform"
        case "zip", "gz", "tgz", "tar", "dmg": return "doc.zipper"
        case "csv", "tsv": return "tablecells"
        case "pdf": return "doc.richtext"
        // A longer one would not fit the room a symbol takes.
        case let ext: return ext.isEmpty || ext.count > 5 ? "doc" : nil
        }
    }

    private static func fileExtension(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).pathExtension.lowercased()
    }
}
