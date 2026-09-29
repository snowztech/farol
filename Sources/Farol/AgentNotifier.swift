import AppKit
import UserNotifications

/// Notifies you when an agent needs you while Farol is in the background, and badges the Dock with the waiting count.
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Clicking a notification opens its session.
    var onOpen: ((UUID) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let settings: AgentSettings

    init(settings: AgentSettings) {
        self.settings = settings
        super.init()
        center.delegate = self
    }

    func activityChanged(_ session: Session, from before: Session.Activity, to after: Session.Activity) {
        guard !NSApp.isActive else { return }
        switch after {
        case .waiting where settings.notifyWaiting:
            // A bell or terminal notification can mean a question or a finished turn. Only hooks tell them apart.
            let body = session.agentIsWaiting
                ? "It needs your approval or an answer to continue." : "Open it to see what it needs."
            post(session, title: "\(session.displayName) is waiting for you", body: body)
        case .done where before == .working && settings.notifyDone:
            post(session, title: "\(session.displayName) is done", body: "Check the result or send the next prompt.")
        default:
            break
        }
    }

    func updateBadge(waiting: Int) {
        NSApp.dockTile.badgeLabel = waiting > 0 ? String(waiting) : nil
    }

    private func post(_ session: Session, title: String, body: String) {
        let id = session.id
        // macOS asks the first time only. After that this returns the saved answer right away.
        center.requestAuthorization(options: [.alert, .sound]) { [center] granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["session": id.uuidString]
            // One notification per session: a newer state replaces the older one.
            center.add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = (response.notification.request.content.userInfo["session"] as? String).flatMap(UUID.init)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let id { self.onOpen?(id) }
        }
        completionHandler()
    }
}
