import AppKit
import Combine
import FarolCore

/// Starts each task's runs while Farol is open. A run missed while the Mac slept or Farol was closed starts as soon as it can.
/// Tasks are the files in `~/.farol/schedules`, read again whenever one changes. What Farol learns running them is kept apart.
final class Scheduler: ObservableObject {
    @Published private(set) var schedules: [Schedule] = []
    /// Files in the folder that aren't a task Farol can read, with why, so a typo shows instead of a task quietly missing.
    @Published private(set) var unreadable: [Unreadable] = []
    /// Tasks whose worktree is being made, so a slow checkout can't start a second run.
    @Published private(set) var starting: Set<String> = []

    struct Unreadable: Equatable {
        let file: URL
        let problem: String
    }

    private static let stateKey = "schedules.state"
    private let store: SessionStore
    private let worktrees: WorktreeSettings
    private var states: [String: Schedule.State]
    private var timer: Timer?
    private var watcher: FolderWatcher?
    private var sessionsChange: AnyCancellable?

    init(store: SessionStore, worktrees: WorktreeSettings) {
        self.store = store
        self.worktrees = worktrees
        states = UserDefaults.standard.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode([String: Schedule.State].self, from: $0) } ?? [:]
        try? FileManager.default.createDirectory(at: ScheduleFile.folder, withIntermediateDirectories: true)
        load()
        watcher = FolderWatcher(ScheduleFile.folder.path) { [weak self] _ in self?.load() }
        // A run opening or closing changes what its task row shows.
        sessionsChange = store.$sessions.sink { [weak self] _ in self?.objectWillChange.send() }
        // Timers stop while the Mac sleeps and fire on waking, so a missed run starts then.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 5
        // After this turn of the run loop, once the last launch's sessions and their runs are restored.
        DispatchQueue.main.async { [weak self] in self?.tick() }
    }

    func file(of schedule: Schedule) -> URL { Self.file(schedule.id) }

    func run(of schedule: Schedule) -> Session? { store.sessions.first { $0.schedule == schedule.id } }

    func schedule(of session: Session) -> Schedule? { session.schedule.flatMap { id in schedules.first { $0.id == id } } }

    func add(_ schedule: Schedule) {
        var schedule = schedule
        schedule.id = ScheduleFile.name(for: schedule) { FileManager.default.fileExists(atPath: Self.file($0).path) }
        schedule.since = .now
        states[schedule.id] = schedule.state
        saveStates()
        write(schedule)
        load()
    }

    /// Resuming owes nothing missed while paused, so it waits for the next time it's due.
    func setPaused(_ paused: Bool, _ id: String) {
        update(id) { saved in
            saved.paused = paused
            if !paused { saved.since = max(saved.since, .now) }
        }
    }

    /// A new time owes nothing missed under the old one, so it waits until it's next due.
    func retime(_ id: String, weekdays: Set<Int>?, once: Date?, hour: Int, minute: Int) {
        update(id) { saved in
            if let weekdays { saved.weekdays = weekdays }
            saved.once = once
            saved.hour = hour
            saved.minute = minute
            saved.since = max(saved.since, .now)
            saved.failure = nil
        }
    }

    /// What runs from the next run on, and when. One already open keeps the prompt it started with.
    /// Saving a task that waits to be allowed allows it, since you've just read what it does.
    func edit(_ id: String, name: String, task: String, weekdays: Set<Int>?, once: Date?, hour: Int, minute: Int) {
        update(id) { saved in
            saved.name = name
            saved.task = task
            saved.allowed = true
        }
        retime(id, weekdays: weekdays, once: once, hour: hour, minute: minute)
    }

    func allow(_ id: String) {
        update(id) { $0.allowed = true }
    }

    /// To the Trash, so a task deleted by mistake can be put back.
    func delete(_ id: String) {
        try? FileManager.default.trashItem(at: Self.file(id), resultingItemURL: nil)
        states[id] = nil
        saveStates()
        store.sessions.filter { $0.schedule == id }.forEach { $0.schedule = nil }
        load()
    }

    /// Starts a run now, whatever the time. One run is open at a time, so an open run is shown instead.
    func run(_ id: String, due: Date? = nil) {
        guard let schedule = schedules.first(where: { $0.id == id }), !starting.contains(id) else { return }
        if let open = run(of: schedule) { return store.select(open) }
        // Run Now is your say-so. A time coming round isn't, for a task you haven't allowed.
        if !schedule.allowed {
            guard due == nil else { return }
            allow(id)
        }
        let now = Date.now
        guard let agent = AgentFolder.choice(schedule.agent, in: AgentFolder.find()) else {
            return update(id) { saved in
                saved.since = now
                saved.failure = "No agent is connected. Connect one in Settings → Agents."
                saved.record(.init(started: now, failure: saved.failure))
            }
        }
        starting.insert(id)
        store.startTask(schedule.task, in: schedule.repos, with: agent, branch: schedule.branch(on: now),
                        copyEnvironmentFiles: worktrees.copyEnvironmentFiles,
                        fromDefaultBranch: worktrees.startFromDefaultBranch, select: due == nil) { [weak self] result in
            guard let self else { return }
            starting.remove(id)
            update(id) { saved in
                saved.since = now
                switch result {
                case .success(let (session, branch)):
                    // A one-time task is done once it starts. Its session is a plain one from then on.
                    if saved.once == nil { session.schedule = id }
                    self.store.rename(session, to: saved.name)
                    saved.lastDue = due
                    saved.failure = nil
                    saved.record(.init(started: now, branch: branch))
                case .failure(let error):
                    saved.failure = "\(error)"
                    saved.record(.init(started: now, failure: saved.failure))
                }
            }
            if case .success = result, schedule.once != nil { delete(id) }
        }
    }

    private static func file(_ id: String) -> URL { ScheduleFile.folder.appendingPathComponent("\(id).md") }

    private func tick() {
        let now = Date.now
        for schedule in schedules where !schedule.paused && schedule.allowed && run(of: schedule) == nil {
            if let due = schedule.owed(at: now) { run(schedule.id, due: due) }
        }
    }

    /// Reads every file again. One seen for the first time owes nothing from before, so an old time in it doesn't start a run.
    private func load() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: ScheduleFile.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var loaded: [Schedule] = []
        var problems: [Unreadable] = []
        for url in files {
            let id = url.deletingPathExtension().lastPathComponent
            do {
                var schedule = try ScheduleFile.parse(String(contentsOf: url, encoding: .utf8), id: id)
                // Farol writes its own tasks' state before their file, so a file with none is one someone else wrote.
                schedule.state = states[id] ?? Schedule.State(since: .now, allowed: false)
                // A time changed in the file owes nothing missed under the old one, as when it's changed in Farol.
                if let before = schedules.first(where: { $0.id == id }), !before.sameTime(as: schedule) {
                    schedule.since = max(schedule.since, .now)
                }
                states[id] = schedule.state
                loaded.append(schedule)
            } catch {
                problems.append(Unreadable(file: url, problem: "\(error)"))
            }
        }
        // Never dropped here: an editor that saves by deleting and writing again leaves a moment with no file, which would lose the past runs.
        saveStates()
        if loaded != schedules { schedules = loaded }
        if problems != unreadable { unreadable = problems }
        syncLaunchAgent()
    }

    /// Rewrites the file only when what's in it changed, so pausing or a run's bookkeeping never touches what you wrote.
    private func update(_ id: String, _ change: (inout Schedule) -> Void) {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        let before = schedules[index]
        change(&schedules[index])
        let after = schedules[index]
        if ScheduleFile.text(for: after) != ScheduleFile.text(for: before) { write(after) }
        states[id] = after.state
        saveStates()
        syncLaunchAgent()
    }

    private func write(_ schedule: Schedule) {
        do {
            try ScheduleFile.text(for: schedule).write(to: Self.file(schedule.id), atomically: true, encoding: .utf8)
        } catch {
            NSLog("Farol couldn't save the task \(schedule.id): \(error)")
        }
    }

    private func saveStates() {
        UserDefaults.standard.set(try? JSONEncoder().encode(states), forKey: Self.stateKey)
    }

    private func syncLaunchAgent() {
        // launchd would open the app without FAROL_HOME, on your own tasks, so a staged scene never asks it to.
        guard !FarolHome.isMoved else { return }
        if let bundle = Bundle.main.bundleIdentifier { LaunchAgent.sync(schedules, bundle: bundle) }
    }
}
