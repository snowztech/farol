import AppKit
import Combine
import FarolCore

/// Starts each schedule's runs while Farol is open. A run missed while the Mac slept or Farol was closed starts as soon as it can.
final class Scheduler: ObservableObject {
    @Published private(set) var schedules: [Schedule] = []
    /// Schedules whose worktree is being made, so a slow checkout can't start a second run.
    @Published private(set) var starting: Set<UUID> = []

    private static let key = "schedules"
    private let store: SessionStore
    private let worktrees: WorktreeSettings
    private var timer: Timer?
    private var sessionsChange: AnyCancellable?

    init(store: SessionStore, worktrees: WorktreeSettings) {
        self.store = store
        self.worktrees = worktrees
        schedules = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Schedule].self, from: $0) } ?? []
        // A run opening or closing changes what its task row shows.
        sessionsChange = store.$sessions.sink { [weak self] _ in self?.objectWillChange.send() }
        // Timers stop while the Mac sleeps and fire on waking, so a missed run starts then.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 5
        // After this turn of the run loop, once the last launch's sessions and their runs are restored.
        DispatchQueue.main.async { [weak self] in self?.tick() }
    }

    func run(of schedule: Schedule) -> Session? { store.sessions.first { $0.schedule == schedule.id } }

    func schedule(of session: Session) -> Schedule? { session.schedule.flatMap { id in schedules.first { $0.id == id } } }

    func add(_ schedule: Schedule) {
        schedules.append(schedule)
        save()
    }

    /// Resuming owes nothing missed while paused, so it waits for the next time it's due.
    func setPaused(_ paused: Bool, _ id: UUID) {
        update(id) { saved in
            saved.paused = paused
            if !paused { saved.since = max(saved.since, .now) }
        }
    }

    /// A new time owes nothing missed under the old one, so it waits until it's next due.
    func retime(_ id: UUID, days: Schedule.Days?, once: Date?, hour: Int, minute: Int) {
        update(id) { saved in
            if let days { saved.days = days }
            saved.once = once
            saved.hour = hour
            saved.minute = minute
            saved.since = max(saved.since, .now)
            saved.failure = nil
        }
    }

    func delete(_ id: UUID) {
        schedules.removeAll { $0.id == id }
        store.sessions.filter { $0.schedule == id }.forEach { $0.schedule = nil }
        save()
    }

    /// Starts a run now, whatever the time. One run is open at a time, so an open run is shown instead.
    func run(_ id: UUID, due: Date? = nil) {
        guard let schedule = schedules.first(where: { $0.id == id }), !starting.contains(id) else { return }
        if let open = run(of: schedule) { return store.select(open) }
        let now = Date.now
        guard let agent = AgentFolder.choice(schedule.agent, in: AgentFolder.find()) else {
            return update(id) { $0.since = now; $0.failure = "No agent is connected. Connect one in Settings → Agents." }
        }
        starting.insert(id)
        store.startTask(schedule.task, in: schedule.repo, with: agent, branch: schedule.branch(on: now),
                        copyEnvironmentFiles: worktrees.copyEnvironmentFiles, select: due == nil) { [weak self] result in
            guard let self else { return }
            starting.remove(id)
            update(id) { saved in
                saved.since = now
                switch result {
                case .success(let (session, _)):
                    // A one-time task is done once it starts. Its session is a plain one from then on.
                    if saved.once == nil { session.schedule = id }
                    self.store.rename(session, to: saved.name)
                    saved.lastDue = due
                    saved.failure = nil
                case .failure(let error):
                    saved.failure = "\(error)"
                }
            }
            if case .success = result, schedule.once != nil { delete(id) }
        }
    }

    private func tick() {
        let now = Date.now
        for schedule in schedules where !schedule.paused && run(of: schedule) == nil {
            if let due = schedule.owed(at: now) { run(schedule.id, due: due) }
        }
    }

    private func update(_ id: UUID, _ change: (inout Schedule) -> Void) {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        change(&schedules[index])
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(schedules), forKey: Self.key)
        if let bundle = Bundle.main.bundleIdentifier { LaunchAgent.sync(schedules, bundle: bundle) }
    }
}
