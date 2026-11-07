import AppKit
import FarolCore
import SwiftUI

/// The whole task in one place: its name, its prompt and when it runs, over how its runs have gone.
/// Where it runs and its branch are shown, not edited, since a change there is rare and its file in ~/.farol/schedules holds them.
struct EditTaskSheet: View {
    struct Edit {
        let name: String
        let task: String
        let weekdays: Set<Int>?
        let once: Date?
        let hour: Int
        let minute: Int
    }

    let schedule: Schedule
    let agent: String
    let kind: AgentFolder.Kind?
    let palette: Palette
    let save: (Edit) -> Void
    let close: () -> Void

    @State private var name: String
    @State private var task: String
    @State private var when: TaskTiming
    @State private var at: Date
    @State private var weekdays: Set<Int>
    @State private var pickingWhen = false
    @State private var taskHeight = TaskField.height(lines: 3)
    @State private var taskFocused = false
    @FocusState private var nameFocused: Bool

    init(schedule: Schedule, agent: String, kind: AgentFolder.Kind?, palette: Palette, save: @escaping (Edit) -> Void,
         close: @escaping () -> Void) {
        self.schedule = schedule
        self.agent = agent
        self.kind = kind
        self.palette = palette
        self.save = save
        self.close = close
        _name = State(initialValue: schedule.name)
        _task = State(initialValue: schedule.task)
        _when = State(initialValue: schedule.once == nil ? .repeats : .later)
        _weekdays = State(initialValue: schedule.weekdays)
        _at = State(initialValue: schedule.once
            ?? Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: .now) ?? .now)
    }

    static func present(_ schedule: Schedule, in window: NSWindow?, palette: Palette, save: @escaping (Edit) -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let folder = AgentFolder.choice(schedule.agent, in: AgentFolder.find())
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        let view = EditTaskSheet(schedule: schedule, agent: folder?.label ?? schedule.agent,
                                 kind: folder?.kind ?? AgentFolder.kind(of: schedule.agent), palette: palette, save: save,
                                 close: { [weak window, weak sheet] in sheet.map { window?.endSheet($0) } })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedTask: String { task.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && !trimmedTask.isEmpty && (when != .later || at > .now) }

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(title: schedule.allowed ? "Edit task" : "Allow this task?", palette: p) {
                    Text(subtitle).fixedSize(horizontal: false, vertical: true)
                }
                field("Name", p) {
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .focused($nameFocused)
                        .sheetField(p, focused: nameFocused)
                }
                field("Prompt", p) {
                    TaskField(placeholder: "What should the agent do?", text: $task, height: $taskHeight, focusRequest: 0, palette: p,
                              focused: { taskFocused = $0 }, attach: { _ in }, submit: commit, cancel: close)
                        .frame(height: taskHeight)
                        .sheetField(p, focused: taskFocused)
                }
                field("Runs", p) { runs(p) }
            }
            .padding(20)
            Rectangle().fill(p.line).frame(height: 1)
            HStack(spacing: 8) {
                WhenButton(label: when.label(at: at, weekdays: weekdays), waiting: true, palette: p) { pickingWhen.toggle() }
                    .popover(isPresented: $pickingWhen, arrowEdge: .top) {
                        WhenChoices(when: $when, at: $at, weekdays: $weekdays, offersNow: false, palette: p) {}
                    }
                // Who runs it, beside when, where the New Task sheet has its agent. Fixed once the task exists.
                HStack(spacing: 6) {
                    if let kind { ToolTile(agent: kind, size: 16) }
                    Text(agent).font(.system(size: 12)).foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(SheetButton(palette: p, primary: false))
                    .keyboardShortcut(.cancelAction)
                Button(schedule.allowed ? "Save" : "Allow", action: commit)
                    .buttonStyle(SheetButton(palette: p, primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(p.text)
        .frame(width: 460)
        .sheetBackground(p)
        .ignoresSafeArea()
    }

    /// Where and as what it runs. A task from someone else's file says so first.
    private var subtitle: String {
        let repos = schedule.repos.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: " + ")
        let runs = schedule.once == nil
            ? "Each run starts \(agent) in \(repos), on a new branch like \(schedule.branch(on: schedule.next(after: .now)))."
            : "Starts \(agent) in \(repos), on a new branch \(schedule.branch)."
        return schedule.allowed ? runs : "This task was made outside Farol, maybe by an agent. Read it, then allow it to run. \(runs)"
    }

    private func field<Content: View>(_ title: String, _ p: Palette, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(p.muted)
            content()
        }
    }

    /// Latest first, a failed start in the color that asks for you. Before the first, when it will be.
    @ViewBuilder private func runs(_ p: Palette) -> some View {
        if schedule.runs.isEmpty {
            Text("No runs yet. The first is \(firstRun).")
                .font(.system(size: 12))
                .foregroundStyle(p.muted)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(schedule.runs.enumerated()), id: \.offset) { _, run in
                        HStack(spacing: 10) {
                            Circle().fill(run.failure == nil ? p.done : p.waiting).frame(width: 6, height: 6)
                            Text(run.started.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                                .monospacedDigit()
                                .frame(width: 120, alignment: .leading)
                            Text(run.failure.map { "didn't start: \($0)" } ?? run.branch ?? "")
                                .font(.system(size: 11, design: run.failure == nil ? .monospaced : .default))
                                .foregroundStyle(run.failure == nil ? p.muted : p.waiting)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .hoverTip(run.failure ?? run.branch ?? "")
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12))
                        .frame(height: 26)
                    }
                }
            }
            .frame(height: min(CGFloat(schedule.runs.count), 5) * 26)
            .sheetField(p, focused: false, padding: 2)
        }
    }

    private var firstRun: String {
        let next = schedule.next(after: .now)
        let calendar = Calendar.current
        let time = next.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(next) { return "today at \(time)" }
        if calendar.isDateInTomorrow(next) { return "tomorrow at \(time)" }
        return "\(next.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))) at \(time)"
    }

    private func commit() {
        guard canSave else { return }
        let calendar = Calendar.current
        save(Edit(name: trimmedName, task: trimmedTask, weekdays: when == .repeats ? weekdays : nil, once: when == .later ? at : nil,
                  hour: calendar.component(.hour, from: at), minute: calendar.component(.minute, from: at)))
        close()
    }
}
