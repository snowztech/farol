import Foundation

/// Preferences for sessions that Farol creates in git worktrees.
final class WorktreeSettings: ObservableObject {
    private static let copyEnvironmentFilesKey = "worktrees.copyEnvironmentFiles"
    private static let startFromDefaultBranchKey = "worktrees.startFromDefaultBranch"

    private let defaults: UserDefaults
    @Published var copyEnvironmentFiles: Bool {
        didSet { defaults.set(copyEnvironmentFiles, forKey: Self.copyEnvironmentFilesKey) }
    }
    /// New branches start from the remote's latest default branch instead of whatever the repo has checked out.
    @Published var startFromDefaultBranch: Bool {
        didSet { defaults.set(startFromDefaultBranch, forKey: Self.startFromDefaultBranchKey) }
    }

    init(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [Self.copyEnvironmentFilesKey: true, Self.startFromDefaultBranchKey: true])
        self.defaults = defaults
        copyEnvironmentFiles = defaults.bool(forKey: Self.copyEnvironmentFilesKey)
        startFromDefaultBranch = defaults.bool(forKey: Self.startFromDefaultBranchKey)
    }
}
