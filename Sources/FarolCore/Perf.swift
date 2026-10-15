import Foundation
import os

/// What Farol spends, for the Farol Inspector (⌥⌘I): every git, gh and glab process, and every hang of the main thread.
/// Always on: a record is a lock and an append, next to a process that takes milliseconds to start.
/// Each process is also an interval in Instruments' Points of Interest, for a closer look.
public final class Perf: @unchecked Sendable {
    public static let shared = Perf()

    public struct Run: Equatable, Sendable {
        /// "git diff": the tool and its first words, enough to tell runs apart without their paths.
        public let command: String
        public let tool: String
        public let start: Date
        public let duration: TimeInterval
        /// Run on the main thread, which freezes the window for as long as it takes.
        public let onMain: Bool
    }

    /// How a reading stands. The lines are here, tested, so a color only ever means something real.
    public enum Level: Int, Comparable, Sendable {
        case good, worthALook, problem

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// The main thread busy for `duration` without a break, so the window couldn't answer.
    public struct Hang: Equatable, Sendable {
        public let start: Date
        public let duration: TimeInterval
    }

    public struct Snapshot: Equatable, Sendable {
        /// The last runs kept, newest first.
        public let recent: [Run]
        /// Every run since launch, kept or not.
        public let total: Int
        public let onMain: Int
        /// The last runs on the main thread, newest first, kept apart so a busy session can't push them out.
        public let blocking: [Run]
        /// The last hangs since launch, newest first.
        public let hangs: [Hang]

        /// Runs per second over the `window` seconds before `now`, by tool.
        public func rate(over window: TimeInterval, at now: Date) -> [String: Double] {
            within(window, at: now).reduce(into: [:]) { rates, run in rates[run.tool, default: 0] += 1 / window }
        }

        /// The `count` longest runs over the `window` seconds before `now`, longest first.
        public func longest(_ count: Int, over window: TimeInterval, at now: Date) -> [Run] {
            Array(within(window, at: now).sorted { $0.duration > $1.duration }.prefix(count))
        }

        /// By the last minute's average: a launch, a session switch or a push starts a burst that's over in seconds, a loop keeps going.
        /// Opening panels and working averages 2 or 3 a second. #159's loop ran 10 a second, for minutes.
        public func processLevel(at now: Date) -> Level {
            let sustained = rate(over: 60, at: now).values.reduce(0, +)
            return sustained < 4 ? .good : sustained < 8 ? .worthALook : .problem
        }

        /// How many runs started over the `window` seconds before `now`, by tool.
        public func started(over window: TimeInterval, at now: Date) -> [String: Int] {
            within(window, at: now).reduce(into: [:]) { counts, run in counts[run.tool, default: 0] += 1 }
        }

        /// Any run on the main thread breaks the rule. Under 100 ms nobody feels it, past that the window stutters.
        public var blockingLevel: Level {
            blocking.isEmpty ? .good : blocking.contains { $0.duration >= 0.1 } ? .problem : .worthALook
        }

        /// Every hang is felt. Past a second it reads as Farol stuck.
        public var hangLevel: Level {
            guard let longest = hangs.map(\.duration).max() else { return .good }
            return longest < 1 ? .worthALook : .problem
        }

        private func within(_ window: TimeInterval, at now: Date) -> [Run] {
            recent.filter { $0.start > now.addingTimeInterval(-window) }
        }
    }

    /// A run under way, from `begin` to `end`.
    public struct Timer {
        let command: String
        let tool: String
        let start: Date
        /// Durations come from a clock that never jumps, unlike the date when macOS sets the time.
        let started: ContinuousClock.Instant
        let onMain: Bool
        let interval: OSSignpostIntervalState
    }

    private let capacity: Int
    private let lock = NSLock()
    private var runs: [Run] = []
    /// Where the next run goes once the ring is full.
    private var next = 0
    private var total = 0
    private var onMain = 0
    private var blocking: [Run] = []
    private var hangs: [Hang] = []
    /// How many blocking runs and hangs are kept, enough to see a pattern.
    private static let kept = 5
    private let signposter = OSSignposter(subsystem: "dev.farol.Farol", category: .pointsOfInterest)

    /// Enough for a minute at 30 processes a second, so the last minute's rate holds even in a loop far past the red line.
    init(capacity: Int = 2048) {
        self.capacity = capacity
    }

    public func begin(_ executable: String, _ arguments: [String]) -> Timer {
        let command = Self.command(executable, arguments)
        let interval = signposter.beginInterval("Command", id: signposter.makeSignpostID(), "\(command, privacy: .public)")
        return Timer(command: command, tool: URL(fileURLWithPath: executable).lastPathComponent, start: Date(),
                     started: .now, onMain: Thread.isMainThread, interval: interval)
    }

    public func end(_ timer: Timer) {
        signposter.endInterval("Command", timer.interval)
        let elapsed = ContinuousClock.now - timer.started
        let duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        record(Run(command: timer.command, tool: timer.tool, start: timer.start, duration: duration, onMain: timer.onMain))
    }

    func record(_ run: Run) {
        lock.withLock {
            if runs.count < capacity { runs.append(run) } else { runs[next] = run }
            next = (next + 1) % capacity
            total += 1
            if run.onMain {
                onMain += 1
                blocking = Array(([run] + blocking).prefix(Self.kept))
            }
        }
    }

    /// Farol with several sessions sits around 200 to 300 MB. A gigabyte means something holds on to too much.
    public static func memoryLevel(_ bytes: UInt64) -> Level {
        bytes < 1 << 30 ? .good : bytes < 2 << 30 ? .worthALook : .problem
    }

    /// Farol itself, near 0 while idle. A quarter of a core that doesn't drop is work nobody asked for.
    public static func cpuLevel(_ percent: Double) -> Level {
        percent < 25 ? .good : percent < 75 ? .worthALook : .problem
    }

    func recordHang(_ hang: Hang) {
        lock.withLock { hangs = Array(([hang] + hangs).prefix(Self.kept)) }
    }

    /// Watches the main run loop for hangs from launch, open inspector or not: two clock reads a pass, no timer, no thread.
    public func watchMainThread() {
        var watch = HangWatch()
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { [weak self] _, activity in
            let now = ProcessInfo.processInfo.systemUptime
            guard let busy = watch.note(at: now, afterSleep: activity == .afterWaiting) else { return }
            self?.recordHang(Hang(start: Date(timeIntervalSinceNow: -busy), duration: busy))
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    public func snapshot() -> Snapshot {
        lock.withLock {
            // The ring's oldest run sits at `next` once it's full.
            let ordered = runs.count < capacity ? runs : Array(runs[next...] + runs[..<next])
            return Snapshot(recent: ordered.reversed(), total: total, onMain: onMain, blocking: blocking, hangs: hangs)
        }
    }

    /// The tool and its first two words, like "git diff" or "gh pr view". Options, numbers and the values of -c and -C are skipped.
    static func command(_ executable: String, _ arguments: [String]) -> String {
        var words: [String] = []
        var skipValue = false
        for argument in arguments where words.count < 2 {
            if skipValue { skipValue = false; continue }
            if argument == "-c" || argument == "-C" { skipValue = true; continue }
            if argument.hasPrefix("-") || Int(argument) != nil { continue }
            words.append(argument)
        }
        let tool = URL(fileURLWithPath: executable).lastPathComponent
        // A shell's command is a whole script, which says nothing at a glance.
        return tool == "zsh" || tool == "bash" ? tool : ([tool] + words).joined(separator: " ")
    }
}

/// The gaps between the main run loop's steps. One that ran 250 ms or more without sleeping is a hang, as Apple counts them.
struct HangWatch {
    private var last: TimeInterval?
    /// Launch keeps the loop busy before the window is there to answer anyone, so counting starts once it first sleeps.
    private var launched = false

    /// Notes a step at `time`, and returns how long the one before it took when that was a hang.
    /// `afterSleep` means the loop was waiting for something to do, which is the opposite of busy.
    mutating func note(at time: TimeInterval, afterSleep: Bool, threshold: TimeInterval = 0.25) -> TimeInterval? {
        defer { last = time }
        if afterSleep { launched = true }
        guard launched, let last, !afterSleep else { return nil }
        let busy = time - last
        return busy >= threshold ? busy : nil
    }
}
