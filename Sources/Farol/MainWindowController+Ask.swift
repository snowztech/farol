import AppKit
import FarolCore

extension MainWindowController {
    /// The session you are looking at asks in its own terminal, as it would without Farol. The hook lets go of the question there.
    func leaveAskToTerminal() {
        guard NSApp.isActive, let session = store.selected, session.ask != nil else { return }
        store.answer(session, with: nil)
    }

    /// Brings Farol forward on a session, from a panel that isn't part of its window.
    func show(session: Session) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        store.select(session)
    }

    /// A button or reply in the notification answers the session's question without opening it.
    func answer(sessionID: UUID, _ choice: AgentNotifier.Choice) {
        guard let session = store.sessions.first(where: { $0.id == sessionID }),
              let question = session.ask?.questions.first, session.ask?.fitsNotification == true else { return }
        let text: String
        switch choice {
        case .chat:
            return store.chat(session)
        case .option(let index):
            guard question.options.indices.contains(index) else { return }
            text = question.options[index].label
        case .text(let typed):
            text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
        }
        store.answer(session, with: [question.text: text])
    }
}
