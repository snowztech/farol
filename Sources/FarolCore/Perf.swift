import Foundation
import os

/// What Farol spends on outside commands: every git, gh and glab run, for the Farol Inspector (⌥⌘I).
/// Always on: a record is a lock and an append, next to a process that takes milliseconds to start.
/// Each run is also an interval in Instruments' Points of Interest, for a closer look.
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

    public struct Snapshot: Equatable, Sendable {
        /// The last runs kept, newest first.
        public let recent: [Run]
        /// Every run since launch, kept or not.
        public let total: Int
        public let onMain: Int

        /// Runs per second over the `window` seconds before `now`, by tool.
        public func rate(over window: TimeInterval, at now: Date) -> [String: Double] {
            within(window, at: now).reduce(into: [:]) { rates, run in rates[run.tool, default: 0] += 1 / window }
        }

        /// The `count` longest runs over the `window` seconds before `now`, longest first.
        public func longest(_ count: Int, over window: TimeInterval, at now: Date) -> [Run] {
            Array(within(window, at: now).sorted { $0.duration > $1.duration }.prefix(count))
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
    private let signposter = OSSignposter(subsystem: "dev.farol.Farol", category: .pointsOfInterest)

    init(capacity: Int = 256) {
        self.capacity = capacity
    }

    public func begin(_ executable: String, _ arguments: [String]) -> Timer {
        let command = Self.command(executable, arguments)
        let interval = signposter.beginInterval("Command", id: signposter.makeSignpostID(), "\(command, privacy: .public)")
        return Timer(command: command, tool: URL(fileURLWithPath: executable).lastPathComponent, start: Date(),
                     onMain: Thread.isMainThread, interval: interval)
    }

    public func end(_ timer: Timer) {
        signposter.endInterval("Command", timer.interval)
        record(Run(command: timer.command, tool: timer.tool, start: timer.start,
                   duration: Date().timeIntervalSince(timer.start), onMain: timer.onMain))
    }

    func record(_ run: Run) {
        lock.withLock {
            if runs.count < capacity { runs.append(run) } else { runs[next] = run }
            next = (next + 1) % capacity
            total += 1
            if run.onMain { onMain += 1 }
        }
    }

    public func snapshot() -> Snapshot {
        lock.withLock {
            // The ring's oldest run sits at `next` once it's full.
            let ordered = runs.count < capacity ? runs : Array(runs[next...] + runs[..<next])
            return Snapshot(recent: ordered.reversed(), total: total, onMain: onMain)
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
