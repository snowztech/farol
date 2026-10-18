import Foundation

/// Paths from Finder, `open` and links clicked in the terminal.
public enum OpenPath {
    /// Where a session starts when it has no other folder to use.
    public static var fallback: String { NSHomeDirectory() }

    /// A directory is used as is, a file's folder is used, and a path that no longer exists is ignored.
    public static func directory(for path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent
    }

    /// The file a clicked link names, and the line when it says one, as in `src/app.ts:42` or `src/app.ts:42:7` the way agents print them.
    /// A relative path is read from `folder`, the pane's. Nil for a URL, a folder or a file that isn't there, which the Mac opens as before.
    public static func file(link: String, in folder: String?) -> (path: String, line: Int?)? {
        var text = link
        if text.hasPrefix("file://") {
            guard let path = URL(string: text)?.path else { return nil }
            text = path
        } else if text.firstMatch(of: #/^[A-Za-z][A-Za-z0-9+.\-]*:(?!\d)/#) != nil {
            // A scheme like https: or mailto:. A colon followed by a digit is a line number instead.
            return nil
        }
        var candidates = [(text, nil as Int?)]
        if let match = text.wholeMatch(of: #/(.+?):(\d+)(?::\d+)?/#) { candidates.append((String(match.1), Int(match.2))) }
        // The whole text first, for the rare file whose name has a colon in it.
        for (path, line) in candidates {
            let expanded = (path as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/") ? expanded : ((folder ?? fallback) as NSString).appendingPathComponent(expanded)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory), !isDirectory.boolValue {
                return ((absolute as NSString).standardizingPath, line)
            }
        }
        return nil
    }
}
