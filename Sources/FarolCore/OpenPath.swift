import Foundation

/// The folder a session starts in for a path from Finder or `open`.
public enum OpenPath {
    /// Where a session starts when it has no other folder to use.
    public static var fallback: String { NSHomeDirectory() }

    /// A directory is used as is, a file's folder is used, and a path that no longer exists is ignored.
    public static func directory(for path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent
    }
}
