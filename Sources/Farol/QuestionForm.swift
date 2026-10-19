import AppKit
import FarolCore
import SwiftUI

/// The colors a question is drawn in on the status panel.
struct QuestionColors {
    let text: Color
    let muted: Color
    let raised: Color
    let line: Color
    let surface: Color
    let primaryFill: Color
    let primaryText: Color

    /// On the notch panel, which is black whatever the theme.
    static let notch = QuestionColors(
        text: .white, muted: .white.opacity(0.5), raised: .white.opacity(0.12), line: .white.opacity(0.14),
        surface: .white.opacity(0.06), primaryFill: .white, primaryText: .black)
}

/// The questions an agent asks, answered here instead of in its terminal.
struct QuestionForm: View {
    let questions: [AgentQuestion]
    let colors: QuestionColors
    /// Who asks, when the form isn't already inside that session.
    var asker: String?
    var maxHeight: CGFloat = 420
    /// The answer to each question, keyed by its text.
    let answer: ([String: String]) -> Void
    /// Turns the question down to talk it over with the agent.
    let chat: () -> Void
    /// Lets the agent ask in its terminal as usual.
    let useTerminal: () -> Void

    @State private var picks: [Int: Set<Int>] = [:]
    @State private var typed: [Int: String] = [:]
    @State private var contentHeight: CGFloat = 0

    /// One question with one pick is answered by the click itself.
    private var instant: Bool { questions.count == 1 && questions[0].multiSelect == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let asker {
                        Text("\(asker) asks").font(.system(size: 11, weight: .semibold)).foregroundStyle(colors.muted)
                    }
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        questionView(index, question)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
            }
            .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
            // The scroll view has no height of its own, so it takes the content's, up to the limit. The first frame is a guess.
            .frame(height: contentHeight == 0 ? 120 : min(contentHeight, maxHeight))
            Rectangle().fill(colors.line).frame(height: 1)
            HStack {
                Button("Chat About This", action: chat)
                    .buttonStyle(QuestionButton(colors: colors, primary: false))
                Spacer(minLength: 8)
                Button("Answer in Terminal", action: useTerminal)
                    .buttonStyle(QuestionButton(colors: colors, primary: false))
                    .keyboardShortcut(.cancelAction)
                if !instant {
                    Button("Send", action: send)
                        .buttonStyle(QuestionButton(colors: colors, primary: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!complete)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .font(.system(size: 13))
        .foregroundStyle(colors.text)
    }

    private func questionView(_ index: Int, _ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.header.isEmpty {
                Text(question.header.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(colors.muted)
            }
            Text(question.text).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(question.options.enumerated()), id: \.offset) { position, option in
                ChoiceRow(
                    title: option.label, detail: option.detail, selected: picks[index]?.contains(position) == true,
                    multiple: question.multiSelect, colors: colors
                ) {
                    pick(index, position, question)
                }
            }
            QuestionField(
                placeholder: "Other", text: Binding(get: { typed[index] ?? "" }, set: { typed[index] = $0 }), colors: colors,
                onSubmit: { if instant, !(typed[index] ?? "").trimmingCharacters(in: .whitespaces).isEmpty { send() } }
            )
            .frame(height: 22)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(colors.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(colors.line))
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

/// The height of what a view draws, passed up to whoever sizes the window around it.
struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One choice, with a radio mark for a single pick and a box for several.
private struct ChoiceRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let multiple: Bool
    let colors: QuestionColors
    let choose: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: multiple ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? colors.text : colors.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).multilineTextAlignment(.leading)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 12)).foregroundStyle(colors.muted).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected || hovering ? colors.raised : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(colors.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onClickableHover { hovering = $0 }
    }
}

/// The form's buttons, in the colors it was given.
private struct QuestionButton: ButtonStyle {
    let colors: QuestionColors
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, colors: colors, primary: primary)
    }

    /// A style can't keep state of its own, and the hover needs some.
    private struct Face: View {
        let configuration: Configuration
        let colors: QuestionColors
        let primary: Bool

        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(primary ? colors.primaryText : colors.text)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(primary ? colors.primaryFill : colors.raised))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .fill((primary ? colors.primaryText : colors.text).opacity(hovering && enabled ? 0.12 : 0)))
                .opacity(!enabled ? 0.35 : configuration.isPressed ? 0.8 : 1)
                .contentShape(Rectangle())
                .onClickableHover { hovering = $0 }
        }
    }
}

/// A one line text field. AppKit's own, since SwiftUI's takes focus unreliably in a panel that isn't the app's main window.
private struct QuestionField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let colors: QuestionColors
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.cell?.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.textColor = NSColor(colors.text)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder, attributes: [.foregroundColor: NSColor(colors.muted), .font: NSFont.systemFont(ofSize: 13)])
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSubmit: onSubmit) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            // Enter confirms a candidate while an input method is composing, and only then sends.
            guard !textView.hasMarkedText() else { return false }
            onSubmit()
            return true
        }
    }
}
