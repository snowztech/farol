import Foundation

/// The folder Farol keeps its own files in: tasks, schedules, servers, worktrees and global commands.
/// `FAROL_HOME` moves it, so a staged screenshot scene never sees or runs your own.
public enum FarolHome {
    private static let moved = ProcessInfo.processInfo.environment["FAROL_HOME"].flatMap { $0.isEmpty ? nil : $0 }
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    public static let url = moved.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? home.appendingPathComponent(".farol", isDirectory: true)

    /// `~/.config/farol/config`, or `config` in `FAROL_HOME` when it's set, so your theme and font stay out of a scene.
    public static let config = moved.map { URL(fileURLWithPath: $0).appendingPathComponent("config") }
        ?? home.appendingPathComponent(".config/farol/config")
}
