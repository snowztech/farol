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
            chat: { [weak self, weak session] in
                guard let self, let session else { return }
                dismissAsk(for: session)
                store.chat(session)
            },
            useTerminal: { [weak self, weak session] in
                guard let self, let session else { return }
                dismissAsk(for: session)
                store.answer(session, with: nil)
            })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        // A sheet has no outside to click, but the window under it still sees the click. It hands the question back.
        let outsideClick = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak session] event in
            guard let self, let session, event.window === self.window, self.askSheet?.session === session else { return event }
            dismissAsk(for: session)
            store.answer(session, with: nil)
            return nil
        }
        askSheet = (sheet, session, outsideClick)
        window.beginSheet(sheet)
    }

    /// Brings Farol forward on a session, from a panel that isn't part of its window.
    func show(session: Session) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        store.select(session)
    }

    func dismissAsk(for session: Session) {
        guard let shown = askSheet, shown.session === session else { return }
        askSheet = nil
        shown.outsideClick.map(NSEvent.removeMonitor)
        window?.endSheet(shown.window)
    }

    /// A button or reply in the notification answers the session's question without opening it.
    func answer(sessionID: UUID, _ choice: AgentNotifier.Choice) {
        guard let session = store.sessions.first(where: { $0.id == sessionID }),
              let question = session.ask?.questions.first, session.ask?.fitsNotification == true else { return }
        let text: String
        switch choice {
        case .chat:
            dismissAsk(for: session)
            return store.chat(session)
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
