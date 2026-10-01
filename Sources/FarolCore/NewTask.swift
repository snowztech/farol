import Foundation

/// A task started from Farol: an agent working on it in its own worktree.
public enum NewTask {
    /// A branch name from the first few words of the task, like "add-fuzzy-search-to-the".
    public static func branchName(for task: String) -> String {
        let words = task.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(5)
        return words.joined(separator: "-")
    }

    /// Single quotes keep every character literal, so a task can't run anything by itself.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
