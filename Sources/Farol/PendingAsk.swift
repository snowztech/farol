import FarolCore
import Foundation

/// A question an agent is blocked on. Its hook keeps the connection open until Farol answers or lets go.
final class PendingAsk {
    /// Tells one question from the next, so a form showing the old one doesn't keep its picks.
    let id = UUID()
    let pane: UUID
    let questions: [AgentQuestion]
    let connection: HeldConnection

    init(pane: UUID, questions: [AgentQuestion], connection: HeldConnection) {
        self.pane = pane
        self.questions = questions
        self.connection = connection
    }

    /// The notification can answer a single question with a few options. Anything else is answered in the window.
    var fitsNotification: Bool {
        guard questions.count == 1, let question = questions.first else { return false }
        return !question.multiSelect && (1...4).contains(question.options.count)
    }
}
