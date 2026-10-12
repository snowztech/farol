import AppKit
import FarolCore
import UserNotifications

/// Notifies you when an agent needs you while Farol is in the background, and badges the Dock with the waiting count.
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Clicking a notification opens its session.
    var onOpen: ((UUID) -> Void)?

    /// What you picked in the notification: one of the question's options, or your own words.
    enum Choice { case option(Int), text(String), chat }
    /// Answering a question from its notification.
    var onAnswer: ((UUID, Choice) -> Void)?

    private let center = UNUserNotificationCenter.current()
    /// One category per question, since its buttons are its options.
    private var categories: [UUID: UNNotificationCategory] = [:]
    private static let optionPrefix = "farol.option."
    private static let textAction = "farol.text"
    private static let chatAction = "farol.chat"

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
            let body = session.prompt?.summary()
                ?? (session.agentIsWaiting ? "It needs your approval or an answer to continue." : "Open it to see what it needs.")
            post(session, title: "\(session.displayName) is waiting for you", body: body)
        case .stopped where settings.notifyWaiting:
            let operation = session.stopped?.kind.command ?? "git"
            let body = session.conflicts > 0
                ? "\(session.conflicts) \(session.conflicts == 1 ? "file is" : "files are") in conflict. Open it to resolve them."
                : "Open it to continue."
            post(session, title: "\(session.displayName): \(operation) stopped", body: body)
        case .done where before == .working && settings.notifyDone:
            post(session, title: "\(session.displayName) is done", body: "Check the result or send the next prompt.")
        default:
            break
        }
    }

    /// Replaces the notification for a waiting agent with one that carries the question, and its options as buttons.
    func asked(_ session: Session, _ ask: PendingAsk) {
        guard !NSApp.isActive, settings.notifyWaiting, let question = ask.questions.first else { return }
        var category: String?
        if ask.fitsNotification {
            var actions: [UNNotificationAction] = question.options.enumerated().map {
                UNNotificationAction(identifier: Self.optionPrefix + String($0.offset), title: $0.element.label, options: [])
            }
            actions.append(UNTextInputNotificationAction(
                identifier: Self.textAction, title: "Other…", options: [],
                textInputButtonTitle: "Send", textInputPlaceholder: "Your answer"))
            // The conversation goes on in the terminal, so this one brings Farol forward.
            actions.append(UNNotificationAction(identifier: Self.chatAction, title: "Chat about this", options: [.foreground]))
            let id = "farol.ask.\(session.id.uuidString)"
            categories[session.id] = UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [])
            center.setNotificationCategories(Set(categories.values))
            category = id
        }
        let prompt = AgentPrompt(text: question.text, options: question.options.map(\.label))
        // The plain notification for this wait already made its sound, and this one takes its place.
        post(session, title: "\(session.displayName) is waiting for you", body: prompt.summary(), category: category, sound: false)
    }

    /// The question is over, so its buttons and its notification have nothing left to do.
    func askEnded(_ session: Session) {
        if categories.removeValue(forKey: session.id) != nil { center.setNotificationCategories(Set(categories.values)) }
        center.removeDeliveredNotifications(withIdentifiers: [session.id.uuidString])
    }

    func updateBadge(waiting: Int) {
        NSApp.dockTile.badgeLabel = waiting > 0 ? String(waiting) : nil
    }

    private func post(_ session: Session, title: String, body: String, category: String? = nil, sound: Bool = true) {
        let id = session.id
        // macOS asks the first time only. After that this returns the saved answer right away.
        center.requestAuthorization(options: [.alert, .sound]) { [center] granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = sound ? .default : nil
            if let category { content.categoryIdentifier = category }
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
        let action = response.actionIdentifier
        // A button answers without bringing Farol forward, which is the point of having it there.
        let choice: Choice? = {
            if action.hasPrefix(Self.optionPrefix), let index = Int(action.dropFirst(Self.optionPrefix.count)) { return .option(index) }
            if action == Self.chatAction { return .chat }
            if action == Self.textAction, let reply = response as? UNTextInputNotificationResponse { return .text(reply.userText) }
            return nil
        }()
        if let id, let choice {
            DispatchQueue.main.async {
                self.onAnswer?(id, choice)
                if case .chat = choice { NSApp.activate(ignoringOtherApps: true); self.onOpen?(id) }
            }
            return completionHandler()
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let id { self.onOpen?(id) }
        }
        completionHandler()
    }
}
