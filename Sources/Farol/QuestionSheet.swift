import FarolCore
import SwiftUI

/// The questions an agent asks, answered here instead of in its terminal.
struct QuestionSheet: View {
    let questions: [AgentQuestion]
    let palette: Palette
    /// The answer to each question, keyed by its text.
    let answer: ([String: String]) -> Void
    /// Turns the question down to talk it over with the agent.
    let chat: () -> Void
    /// Lets the agent ask in its terminal as usual.
    let useTerminal: () -> Void

    @State private var picks: [Int: Set<Int>] = [:]
    @State private var typed: [Int: String] = [:]
    @FocusState private var focused: Int?

    /// One question with one pick is answered by the click itself.
    private var instant: Bool { questions.count == 1 && questions[0].multiSelect == false }

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        questionView(index, question, p)
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 480)
            Rectangle().fill(p.line).frame(height: 1)
            HStack {
                Button("Chat About This", action: chat)
                    .buttonStyle(SheetButton(palette: p, primary: false))
                Spacer()
                Button("Answer in Terminal", action: useTerminal)
                    .buttonStyle(SheetButton(palette: p, primary: false))
                    .keyboardShortcut(.cancelAction)
                if !instant {
                    Button("Send", action: send)
                        .buttonStyle(SheetButton(palette: p, primary: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!complete)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460)
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .background(p.background)
    }

    private func questionView(_ index: Int, _ question: AgentQuestion, _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.header.isEmpty {
                Text(question.header.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted)
            }
            Text(question.text).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(question.options.enumerated()), id: \.offset) { position, option in
                ChoiceRow(
                    title: option.label, detail: option.detail, selected: picks[index]?.contains(position) == true,
                    multiple: question.multiSelect, palette: p
                ) {
                    pick(index, position, question)
                }
            }
            TextField("Other", text: Binding(get: { typed[index] ?? "" }, set: { typed[index] = $0 }))
                .textFieldStyle(.plain)
                .focused($focused, equals: index)
                .sheetField(p, focused: focused == index)
                .onSubmit { if instant, !(typed[index] ?? "").isEmpty { send() } }
        }
    }

    private func pick(_ index: Int, _ position: Int, _ question: AgentQuestion) {
        if question.multiSelect {
            var set = picks[index] ?? []
            if set.contains(position) { set.remove(position) } else { set.insert(position) }
            picks[index] = set
        } else {
            picks[index] = [position]
            typed[index] = nil
            if instant { send() }
        }
    }

    /// Your own words count as a pick, and in a single choice they replace it.
    private func answerText(_ index: Int) -> String? {
        let question = questions[index]
        let text = (typed[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var labels = question.options.enumerated().filter { picks[index]?.contains($0.offset) == true }.map(\.element.label)
        if !text.isEmpty { labels = question.multiSelect ? labels + [text] : [text] }
        return labels.isEmpty ? nil : AskHook.join(labels)
    }

    private var complete: Bool { questions.indices.allSatisfy { answerText($0) != nil } }

    private func send() {
        guard complete else { return }
        answer(Dictionary(uniqueKeysWithValues: questions.indices.map { (questions[$0].text, answerText($0)!) }))
    }
}

/// One choice, with a radio mark for a single pick and a box for several.
private struct ChoiceRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let multiple: Bool
    let palette: Palette
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: multiple ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? palette.text : palette.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 12)).foregroundStyle(palette.muted).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? palette.raised : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
