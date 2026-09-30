import Foundation

/// Preferences for sessions that Farol creates in git worktrees.
final class WorktreeSettings: ObservableObject {
    private static let copyEnvironmentFilesKey = "worktrees.copyEnvironmentFiles"

    private let defaults: UserDefaults
    @Published var copyEnvironmentFiles: Bool {
        didSet { defaults.set(copyEnvironmentFiles, forKey: Self.copyEnvironmentFilesKey) }
    }

    init(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [Self.copyEnvironmentFilesKey: true])
        self.defaults = defaults
        copyEnvironmentFiles = defaults.bool(forKey: Self.copyEnvironmentFilesKey)
    }
}
