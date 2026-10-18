import AppKit
import Sparkle

/// Sparkle looks for a new version once a day, and the title bar shows a quiet Update button instead of Sparkle's window.
/// Clicking it opens Sparkle, which downloads the update, checks its signature and relaunches Farol on it.
final class UpdateChecker: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    @Published private(set) var available: String?

    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        // Dev builds have no feed, so they never offer to replace themselves with a release.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Also what Check for Updates in the Farol menu does.
    func install() {
        controller?.checkForUpdates(nil)
    }

    var canCheck: Bool { controller != nil }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A check Sparkle runs on its own shows the button. A check you asked for opens Sparkle's window right away.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { available = update.displayVersionString }
    }

    func standardUserDriverWillFinishUpdateSession() {
        available = nil
    }
}
