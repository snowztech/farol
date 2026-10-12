import AppKit
import FarolCore
import SwiftUI

extension MainWindowController {
    /// Shows the selected session's question, if it has one. Never over another sheet, and never for a session you aren't in.
    func presentAsk() {
        guard NSApp.isActive, let window, window.attachedSheet == nil, askSheet == nil,
              let session = store.selected, let ask = session.ask else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        let view = QuestionSheet(
            questions: ask.questions, palette: state.palette,
            answer: { [weak self, weak session] answers in
                guard let self, let session else { return }
                // Closed first, so the sheet is gone by the time the agent's next message arrives.
                dismissAsk(for: session)
                store.answer(session, with: answers)
            },
            useTerminal: { [weak self, weak session] in
                guard let self, let session else { return }
                dismissAsk(for: session)
                store.answer(session, with: nil)
            })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        askSheet = (sheet, session)
        window.beginSheet(sheet)
    }

    func dismissAsk(for session: Session) {
        guard let shown = askSheet, shown.session === session else { return }
        askSheet = nil
        window?.endSheet(shown.window)
    }

    /// A button or reply in the notification answers the session's question without opening it.
    func answer(sessionID: UUID, _ choice: AgentNotifier.Choice) {
        guard let session = store.sessions.first(where: { $0.id == sessionID }),
              let question = session.ask?.questions.first, session.ask?.fitsNotification == true else { return }
        let text: String
        switch choice {
        case .option(let index):
            guard question.options.indices.contains(index) else { return }
            text = question.options[index].label
        case .text(let typed):
            text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
        }
        dismissAsk(for: session)
        store.answer(session, with: [question.text: text])
    }
}
