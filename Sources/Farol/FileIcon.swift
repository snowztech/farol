import FarolCore
import Foundation

/// A symbol for what kind of file a path is, so a list of files reads at a glance. Drawn in gray, since color means agent status.
enum FileIcon {
    static func symbol(for path: String, folder: Bool = false) -> String {
        if folder || path.hasSuffix("/") { return "folder" }
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.hasPrefix(".env") { return "key" }
        if name.hasSuffix(".lock") || name.hasSuffix("-lock.json") || name.hasSuffix(".resolved") { return "lock" }
        if ["makefile", "dockerfile", "justfile", "rakefile"].contains(name) { return "hammer" }
        switch (name as NSString).pathExtension {
        case "swift": return "swift"
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
