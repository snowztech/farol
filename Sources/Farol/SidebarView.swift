import Combine
import FarolCore
import SwiftUI

struct SidebarView: View {
    static let defaultWidth: CGFloat = 224

    @ObservedObject var store: SessionStore
    @ObservedObject var state: WindowState
    @ObservedObject var scheduler: Scheduler
    let commands: Commands
    let resize: (CGFloat) -> Void

    @State private var dragging: Session?
    /// The selection's highlight is one shape that moves to the row you pick.
    @Namespace private var selection
    @State private var dragStart: CGFloat?
    /// Only read so the sidebar redraws when the setting changes. The store applies it.
    @AppStorage(SessionStore.groupByRepoKey) private var groupByRepo = false
    /// The projects folded shut, by repo path, one per line.
    @AppStorage("sidebar.folded") private var folded = ""
    @ObservedObject private var proto = ServersPrototype.shared

    var body: some View {
        let p = state.palette
        let onServer = ServersPrototype.enabled && proto.variant == .machines && proto.machine != nil
        VStack(spacing: 0) {
            if ServersPrototype.enabled && proto.variant == .machines {
                ServersPrototypeMachines(localActivities: store.groups.flatMap(\.items).map(\.activity), palette: p)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    if onServer { ServersPrototypeMachineList(palette: p) }
                    ForEach(onServer ? [] : store.groups, id: \.key) { group in
                        let name = group.key.map { URL(fileURLWithPath: $0).lastPathComponent }
                        let shut = group.key.map(isFolded) ?? false
                        if let key = group.key, let name {
                            ProjectHeader(name: name, sessions: group.items, folded: shut,
                                          holdsSelection: group.items.contains { $0.id == store.selectedID }, palette: p,
                                          onToggle: { toggleFold(key) }, onNew: { commands.newSessionIn(key) })
                        }
                        ForEach(shut ? [] : group.items) { session in
                            SessionRow(
                                session: session,
                                selected: session.id == store.selectedID && !state.showingSettings,
                                schedule: scheduler.schedule(of: session),
                                scheduler: scheduler,
                                palette: p,
                                highlight: selection,
                                // Reselecting would pull focus back into the terminal, which a rename would lose.
                                onSelect: {
                                    if session.id != store.selectedID || state.showingSettings { store.select(session) }
                                },
                                onRename: { store.rename(session, to: $0) },
                                onClose: { commands.closeSession(session) })
                            .onDrag {
                                dragging = session
                                return NSItemProvider(object: session.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: Reorder(target: session, store: store, dragging: $dragging))
                        }
                    }
                    if ServersPrototype.enabled && proto.variant == .group { ServersPrototypeGroups(palette: p) }
                    if ServersPrototype.enabled && proto.variant == .mixed { ServersPrototypeMixed(palette: p) }
                }
                .padding(8)
                .animation(Motion.enabled ? .spring(response: 0.32, dampingFraction: 0.86) : nil, value: store.selectedID)
            }
            // Only once there is a task, so a new user never meets an empty pane.
            if !scheduler.schedules.isEmpty || !scheduler.unreadable.isEmpty {
                TasksPane(scheduler: scheduler, store: store, palette: p)
            }
            // Pinned below the list, so it stays in the same place however many sessions there are.
            if ServersPrototype.enabled && proto.variant == .mixed { ServersPrototypeNewMenu(palette: p) }
            NewTaskRow(palette: p, action: commands.newTask)
                .padding(8)
            if ServersPrototype.enabled { ServersPrototypeSwitcher() }
        }
        .sheet(isPresented: $proto.adding) { ServersPrototypeAddSheet(palette: p) }
        // Reaching a session in a folded project, with ⌘1 to ⌘9, a notification or a new session, opens the project so the row is there.
        // A new session's repo is found a moment after it's selected, so the repo is watched too.
        .onChange(of: store.selectedID) { revealSelected() }
        .onChange(of: store.selected?.repoRoot) { revealSelected() }
        // Fixed width, so collapsing the sidebar clips it instead of reflowing every row.
        .frame(width: state.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(p.panel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(p.boxed ? .clear : p.line).frame(width: 1)
                .frame(width: 7, alignment: .trailing)
                .contentShape(Rectangle())
                .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
                .gesture(DragGesture(coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStart ?? state.sidebarWidth
                        dragStart = start
                        resize(start + drag.translation.width)
                    }
                    .onEnded { _ in dragStart = nil })
        }
    }

    private func revealSelected() {
        guard let key = store.selected?.repoRoot, isFolded(key) else { return }
        toggleFold(key)
    }

    private func isFolded(_ key: String) -> Bool {
        folded.split(separator: "\n").contains { $0 == key }
    }

    private func toggleFold(_ key: String) {
        var keys = folded.split(separator: "\n").map(String.init)
        if let index = keys.firstIndex(of: key) { keys.remove(at: index) } else { keys.append(key) }
        withAnimation(.easeOut(duration: 0.15)) { folded = keys.joined(separator: "\n") }
    }
}

private struct SessionRow: View {
    @ObservedObject var session: Session
    let selected: Bool
    let schedule: Schedule?
    let scheduler: Scheduler
    let palette: Palette
    let highlight: Namespace.ID
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onClose: () -> Void

    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Lamp(activity: session.activity, selected: selected, palette: palette)

            labels.lineLimit(1)

            Spacer(minLength: 0)

            if hovering && !editing {
                CloseButton(help: "Close session (⌘W)", palette: palette, action: onClose)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background { background }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        // Alongside the single tap, not instead of it, so selecting never waits for a possible second click.
        .simultaneousGesture(TapGesture(count: 2).onEnded { startEditing() })
        .onClickableHover { hovering = $0 }
        .contextMenu {
            Button("Rename", action: startEditing)
            Button("Close Session", action: onClose)
            if let schedule { ScheduleItems(schedule: schedule, scheduler: scheduler) }
            // Over ssh the folder is on the server, where the Mac's apps can't reach it.
            if !session.isRemote {
                Divider()
                OpenInItems(path: session.topLevel ?? session.directory)
            }
        }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 1) {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: fieldFocused) { _, focused in if !focused { commit() } }
            } else {
                let name = Text(session.displayName)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? palette.text : palette.text.opacity(0.8))
                if session.isWorktreeCheckout || schedule != nil {
                    // The name gives way first, so the tag stays whole and never shrinks to a stray "w…".
                    HStack(spacing: 6) {
                        name.lineLimit(1).truncationMode(.tail)
                        if let schedule {
                            Image(systemName: "clock")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(palette.muted)
                                .layoutPriority(1)
                                .hoverTip(schedule.runTip)
                        }
                        if session.isWorktreeCheckout {
                            Badge(text: "worktree", small: true, palette: palette)
                                .layoutPriority(1)
                                .hoverTip("Worktree · \(session.topLevel ?? session.taskFolder ?? session.directory)")
                        }
                    }
                } else {
                    name
                }
            }
            if let waiting = session.waitingFor {
                // In place of the branch while the agent waits, so the row says what for without being opened.
                Text(waiting)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                    .truncationMode(.tail)
                    .hoverTip(waiting)
            } else {
                HStack(spacing: 6) {
                    // Ahead of the spacer, which would otherwise take half the room and cut the branch short.
                    Group {
                        if let branch = gitLine {
                            HStack(spacing: 4) {
                                BranchMark(color: palette.muted)
                                Text(branch).truncationMode(.middle)
                            }
                        } else if let location = session.remoteLocation ?? session.location {
                            Text(location).truncationMode(.head)
                        }
                    }
                    .layoutPriority(1)
                    // The branch gives way first, so a port is always whole.
                    Spacer(minLength: 4)
                    if let port = session.ports.first { PortLink(port: port, palette: palette) }
                    if session.ports.count > 1 {
                        Text(verbatim: "+\(session.ports.count - 1)")
                            .fixedSize()
                            .hoverTip("Also on " + session.ports.dropFirst().map { "localhost:\($0)" }.joined(separator: ", "))
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.muted)
            }
        }
    }

    /// The branch, and what is left to do while git is stopped. In the row's usual gray, since the lamp already asks for you.
    private var gitLine: String? {
        guard session.stopped != nil else { return session.remoteLocation == nil ? session.branch : nil }
        let left = session.conflicts == 0 ? "ready to continue"
            : "\(session.conflicts) \(session.conflicts == 1 ? "conflict" : "conflicts")"
        return [session.branch, left].compactMap { $0 }.joined(separator: " · ")
    }

    private func startEditing() {
        draft = session.displayName
        editing = true
        // The field only exists after this update, so focus it on the next turn.
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        onRename(draft)
    }

    /// Selection stays neutral, so color only ever means agent status. A faint edge lifts it off the panel.
    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if selected {
            shape.fill(palette.selection)
                .overlay(shape.strokeBorder(palette.line))
                .matchedGeometryEffect(id: "selection", in: highlight)
        } else {
            shape.fill(hovering ? palette.hover : .clear)
        }
    }
}

/// The way to start a task, at the foot of the sidebar where the tasks live. Quiet until hovered.
/// What will run, under what runs now. Lighter than the sessions above: tasks are plans, not places to go.
private struct TasksPane: View {
    @ObservedObject var scheduler: Scheduler
    let store: SessionStore
    let palette: Palette

    @AppStorage("sidebar.tasksFolded") private var folded = false
    @State private var hovering = false
    static let rowHeight: CGFloat = 40
    private static let groupHeight: CGFloat = 24

    var body: some View {
        let p = palette
        let tasks = scheduler.schedules.sorted { $0.next(after: .now) < $1.next(after: .now) }
        let groups = Grouping.group(tasks) { $0.repos.joined(separator: "\n") }
        VStack(spacing: 0) {
            Rectangle().fill(p.line).frame(height: 1)
            HStack(spacing: 6) {
                Text("Tasks").font(.system(size: 12, weight: .medium))
                Text(verbatim: "\(tasks.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted.opacity(0.7))
                if folded, let next = tasks.first(where: { !$0.paused }) {
                    Text("next \(next.upcoming(at: .now))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(p.muted.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // Like a project's, quiet until you point at it.
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .frame(width: 20, height: 20)
                    .opacity(hovering || folded ? 1 : 0.35)
            }
            .foregroundStyle(hovering ? p.text : p.muted)
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .frame(height: 32)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Motion.enabled ? .easeOut(duration: 0.15) : nil) { folded.toggle() } }
            .onClickableHover { hovering = $0 }
            .hoverTip(folded ? "Show tasks" : "Fold tasks")
            if !folded {
                let rows = tasks.count + scheduler.unreadable.count
                let height = CGFloat(rows) * Self.rowHeight + (groups.count > 1 ? CGFloat(groups.count) * Self.groupHeight : 0)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.key) { group in
                            if groups.count > 1, let key = group.key {
                                Text(key.split(separator: "\n").map { URL(fileURLWithPath: String($0)).lastPathComponent }.joined(separator: " + "))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(p.muted.opacity(0.8))
                                    .padding(.leading, 10)
                                    .frame(height: Self.groupHeight, alignment: .bottomLeading)
                            }
                            ForEach(group.items) { task in
                                TaskRow(task: task, run: scheduler.run(of: task), starting: scheduler.starting.contains(task.id),
                                        scheduler: scheduler, store: store, palette: p)
                            }
                        }
                        ForEach(scheduler.unreadable, id: \.file) { UnreadableRow(unreadable: $0, palette: p) }
                    }
                    .padding(.horizontal, 8)
                }
                // As tall as its rows up to four and a half, so it never takes the sessions' room and a cut row says there are more.
                .frame(height: min(height, 4.5 * Self.rowHeight))
                .padding(.bottom, 4)
            }
        }
    }
}

/// A file in the tasks folder Farol can't read, with why on hover. Clicking opens it to fix.
private struct UnreadableRow: View {
    let unreadable: Scheduler.Unreadable
    let palette: Palette

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(unreadable.file.deletingPathExtension().lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(palette.text.opacity(0.85))
            Text("can't read · click to fix")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.waiting)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: TasksPane.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(unreadable.file) }
        .onClickableHover { hovering = $0 }
        .hoverTip("\(unreadable.file.lastPathComponent): \(unreadable.problem)")
    }
}

/// One task: its name, when it runs under it, and the run's own lamp on the right while it runs.
/// Clicking it changes when it runs, or opens its run while one is open.
private struct TaskRow: View {
    let task: Schedule
    let run: Session?
    let starting: Bool
    let scheduler: Scheduler
    let store: SessionStore
    let palette: Palette

    @State private var hovering = false

    var body: some View {
        let p = palette
        // Lined up with the Tasks heading, not the sessions' lamps: a task is a plan to read, and live state sits on the right.
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .font(.system(size: 12))
                    .foregroundStyle(task.paused ? p.muted : p.text.opacity(0.85))
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    // Which agent will run it, which the name and time alone don't say.
                    if let kind = AgentFolder.kind(of: task.agent) {
                        ToolTile(agent: kind, size: 13).opacity(task.paused ? 0.5 : 1)
                    }
                    if task.once == nil, run == nil, task.failure == nil, task.allowed {
                        Image(systemName: "repeat").font(.system(size: 9, weight: .semibold))
                    }
                    Text(when)
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(task.failure != nil || !task.allowed ? p.waiting : p.muted)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            trailing(p)
        }
        .padding(.horizontal, 10)
        .frame(height: TasksPane.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? p.hover : .clear))
        .contentShape(Rectangle())
        // One place to change a task, its name, prompt and time together, rather than a popover for the time and a sheet for the rest.
        .onTapGesture { if let run { store.select(run) } else { openEditor() } }
        .onClickableHover { hovering = $0 }
        .hoverTip(tip)
        .contextMenu {
            Button("Run Now") { scheduler.run(task.id) }
            Button("Edit Task…", action: openEditor)
            // Each task is a Markdown file you can edit anywhere, sync or hand to an agent.
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([scheduler.file(of: task)]) }
            ScheduleItems(schedule: task, scheduler: scheduler)
        }
    }

    /// The sheet also asks to allow a task from someone else's file, so you read what it does before it can run.
    private func openEditor() {
        EditTaskSheet.present(task, in: NSApp.keyWindow, palette: palette) { edit in
            scheduler.edit(task.id, name: edit.name, task: edit.task, weekdays: edit.weekdays, once: edit.once, hour: edit.hour,
                           minute: edit.minute)
        }
    }

    @ViewBuilder private func trailing(_ p: Palette) -> some View {
        if starting {
            ProgressView().controlSize(.mini)
        } else if let run {
            RunLamp(session: run, palette: p)
        } else if !task.allowed {
            Button("Allow") { scheduler.allow(task.id) }
                .buttonStyle(SheetButton(palette: p, primary: false))
                .hoverTip("Let it run at its times. Click the task to read it first.")
        } else if hovering {
            CloseButton(symbol: "play.fill", help: "Run now", palette: p) { scheduler.run(task.id) }
        }
    }

    /// The second line: when it runs in the words a calendar would use, or why it isn't waiting.
    private var when: String {
        if run != nil { return "running" }
        if !task.allowed { return "waits for your OK" }
        if task.failure != nil { return "didn't start" }
        let time = task.once.map { once in
            Calendar.current.isDateInToday(once) ? "today \(task.upcoming(at: .now))" : task.upcoming(at: .now)
        } ?? "\(Schedule.days(task.weekdays)) \(Schedule.clock(hour: task.hour, minute: task.minute))"
        return task.paused ? "paused · \(time)" : time
    }

    private var tip: String {
        if !task.allowed { return "Made outside Farol, maybe by an agent. It won't run until you allow it. Click to read it first." }
        if let failure = task.failure { return "Didn't start: \(failure)" }
        if run != nil { return "Running. The next run waits until you close this one." }
        let what = task.once == nil ? "Runs \(task.rule)." : "Runs once, \(task.rule)."
        return task.paused ? "Paused. \(what)" : what
    }
}

/// The lamp of a task's open run, kept live as its agent works.
private struct RunLamp: View {
    @ObservedObject var session: Session
    let palette: Palette

    var body: some View { Lamp(activity: session.activity, selected: false, palette: palette) }
}

/// Pausing and deleting, the same on a schedule's row and on its open run.
private struct ScheduleItems: View {
    let schedule: Schedule
    let scheduler: Scheduler

    var body: some View {
        Divider()
        Button(schedule.paused ? "Resume Task" : "Pause Task") { scheduler.setPaused(!schedule.paused, schedule.id) }
        Button("Delete Task") { scheduler.delete(schedule.id) }
    }
}

extension Schedule {
    /// What the clock on an open run says.
    var runTip: String {
        var lines = ["Runs \(rule). The next run waits until you close this one."]
        if startedLate {
            lines.append("This one started at \(since.formatted(date: .omitted, time: .shortened)), late because the Mac was asleep or Farol was closed.")
        }
        if paused { lines.append("Paused.") }
        return lines.joined(separator: "\n")
    }
}

private struct NewTaskRow: View {
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(QuietPress())
            .onClickableHover { hovering = $0 }
    }

    private var label: some View {
        HStack(spacing: 10) {
            // Same width as the status dots, so the label lines up with session names.
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: Lamp.size)
            Text("New task")
                .font(.system(size: 13))
            Spacer(minLength: 0)
            if hovering {
                Text("⇧⌘N")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.muted)
            }
        }
        .foregroundStyle(hovering ? palette.text : palette.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
    }
}

/// A repo's name above its sessions, only there once sessions span several repos.
struct RepoHeader: View {
    let name: String
    let palette: Palette
    /// At the top of its list, where the room above it is the list's own, so it adds none.
    var first = false

    var body: some View {
        Text(name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.muted)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, first ? 2 : 12)
            .padding(.bottom, 4)
    }
}

/// A project's name above its sessions, the whole row a button that folds them away.
/// Folded, it shows how many there are and, in the lamp column, the most pressing lamp among them.
private struct ProjectHeader: View {
    let name: String
    let sessions: [Session]
    let folded: Bool
    /// Folded with the session on screen inside, it takes the selection's highlight so you can see where it went.
    let holdsSelection: Bool
    let palette: Palette
    let onToggle: () -> Void
    let onNew: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // The session lamps' column, so the project name lines up with session names.
            ZStack {
                if folded { FoldedLamp(sessions: sessions, palette: palette) }
            }
            .frame(width: Lamp.size)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? palette.text : palette.muted)
            if folded {
                Text(verbatim: "\(sessions.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.muted.opacity(0.7))
            }
            Spacer(minLength: 0)
            if hovering {
                CloseButton(symbol: "plus", help: "New session in \(name)", palette: palette, action: onNew)
            }
            // Faint while open, so the header still reads as one that folds, and full when folded or hovered.
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? palette.text : palette.muted)
                .rotationEffect(.degrees(folded ? 0 : 90))
                .frame(width: 20, height: 20)
                .opacity(hovering || folded ? 1 : 0.35)
        }
        .lineLimit(1)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(folded && holdsSelection ? palette.selection : hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onClickableHover { hovering = $0 }
        .hoverTip(folded ? "Show \(name)'s sessions" : "Fold \(name)")
        .padding(.top, 10)
    }
}

/// The lamp a folded project shows for its sessions, so an agent waiting inside never goes unseen.
private struct FoldedLamp: View {
    let sessions: [Session]
    let palette: Palette

    /// Bumped whenever a session changes, since the header doesn't observe each one.
    @State private var changes = 0

    var body: some View {
        let _ = changes
        // Ordered by who needs you: git stopped, an agent asking, an agent finished, then one still working.
        let pressing: [Session.Activity] = [.stopped, .waiting, .done, .working]
        let activity = pressing.first { level in sessions.contains { $0.activity == level } } ?? .idle
        Lamp(activity: activity, selected: false, palette: palette)
            .onReceive(Publishers.MergeMany(sessions.map(\.objectWillChange))) { _ in changes += 1 }
    }
}

/// Moves the dragged session live as it passes over other rows.
private struct Reorder: DropDelegate {
    let target: Session
    let store: SessionStore
    @Binding var dragging: Session?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging !== target,
              let index = store.sessions.firstIndex(where: { $0 === target }) else { return }
        // A session's section comes from its folder, so it only moves within its own repo.
        let grouped = store.groups.contains { $0.key != nil }
        guard !grouped || dragging.repoRoot == target.repoRoot else { return }
        withAnimation(.easeOut(duration: 0.15)) { store.move(dragging, to: index) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Hollow when nothing is happening, breathing while the agent works, rippling when it waits for you, filled when it is done.
struct Lamp: View {
    /// Every column that lines up with the lamps uses this width.
    static let size: CGFloat = 7

    let activity: Session.Activity
    /// A session you are looking at has no need to ripple.
    let selected: Bool
    let palette: Palette

    var body: some View {
        ZStack {
            switch activity {
            case .idle: Circle().strokeBorder(palette.muted.opacity(0.5), lineWidth: 1.2)
            case .working: Breathing(color: palette.working)
            case .waiting, .stopped:
                // A ripple asks for attention, which a working dot never does.
                if !selected { Ripple(color: palette.waiting) }
                Circle().fill(palette.waiting)
            case .done: Circle().fill(palette.done)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .hoverTip(help)
    }

    private var help: String {
        switch activity {
        case .idle: ""
        case .working: "Working"
        case .waiting: "Waiting for your approval or an answer"
        case .done: "Done. Your turn"
        case .stopped: "Git stopped. Resolve and continue (⌥⌘M)"
        }
    }
}

/// Each animation keeps its own state, so switching between them always starts clean.
private struct Breathing: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .opacity(dim ? 0.25 : 0.9)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever()) { dim = true }
            }
    }
}

private struct Ripple: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var out = false

    var body: some View {
        Circle()
            .fill(color)
            .scaleEffect(out ? 2.6 : 1)
            .opacity(out ? 0 : (reduceMotion ? 0 : 0.5))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { out = true }
            }
    }
}

/// A port the session's programs listen on, muted like the branch until hovered, and opened in the browser on click.
private struct PortLink: View {
    let port: Int
    let palette: Palette

    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!)
        } label: {
            Text(verbatim: ":\(port)")
                .foregroundStyle(hovering ? palette.text : palette.muted)
                .underline(hovering)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onClickableHover { hovering = $0 }
        .hoverTip("Open localhost:\(port)")
    }
}

/// The system branch symbol's arrow draws too much attention beside a small branch name.
struct BranchMark: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let unit = size.width / 12
            var line = Path()
            line.move(to: CGPoint(x: 3 * unit, y: 2 * unit))
            line.addLine(to: CGPoint(x: 3 * unit, y: 10 * unit))
            line.move(to: CGPoint(x: 9 * unit, y: 2 * unit))
            line.addLine(to: CGPoint(x: 9 * unit, y: 4 * unit))
            line.addQuadCurve(to: CGPoint(x: 3 * unit, y: 8 * unit),
                              control: CGPoint(x: 9 * unit, y: 8 * unit))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: unit, lineCap: .round))
            for point in [CGPoint(x: 3 * unit, y: 2 * unit), CGPoint(x: 9 * unit, y: 2 * unit),
                          CGPoint(x: 3 * unit, y: 10 * unit)] {
                let dot = Path(ellipseIn: CGRect(x: point.x - 1.4 * unit, y: point.y - 1.4 * unit,
                                                 width: 2.8 * unit, height: 2.8 * unit))
                context.fill(dot, with: .color(color))
            }
        }
        .frame(width: 11, height: 11)
        .accessibilityHidden(true)
    }
}
