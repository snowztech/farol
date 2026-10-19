import FarolCore
import SwiftUI

/// The questions an agent asks, in a sheet over Farol's window.
struct QuestionSheet: View {
    let questions: [AgentQuestion]
    let palette: Palette
    let answer: ([String: String]) -> Void
    let chat: () -> Void
    let useTerminal: () -> Void

    var body: some View {
        QuestionForm(
            questions: questions, colors: QuestionColors(palette: palette), maxHeight: 480,
            answer: answer, chat: chat, useTerminal: useTerminal)
            .frame(width: 460)
            .background(palette.background)
    }
}
