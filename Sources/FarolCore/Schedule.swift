import Foundation

/// A New Task that starts later, once or again at a set time, in a new worktree each run.
public struct Schedule: Codable, Equatable, Identifiable, Sendable {
    public enum Days: String, Codable, CaseIterable, Sendable {
        case everyDay, weekdays

        public var label: String {
            switch self {
            case .everyDay: "Every day"
            case .weekdays: "Weekdays"
            }
        }
    }

    public var id = UUID()
    public var name: String
    public var task: String
    /// The repository each run branches from.
    public var repo: String
    /// Each run's branch starts with it and ends with the day, like write-article-2026-11-06.
    public var branch: String
    /// An agent config folder's id, as the New Task sheet saves it.
    public var agent: String
    public var days: Days
    /// Set for a task that runs once, at this time, instead of on `days`.
    public var once: Date?
    public var hour: Int
    public var minute: Int
    public var paused = false
    /// When the last run started, or when the schedule was made. Nothing due before it is owed.
    public var since: Date
    /// When the last run was due, to tell a late start from one on time.
    public var lastDue: Date?
    /// Why the last run didn't start, until one does.
    public var failure: String?

    public init(name: String, task: String, repo: String, branch: String, agent: String, days: Days, hour: Int, minute: Int, since: Date) {
        self.name = name
        self.task = task
        self.repo = repo
        self.branch = branch
        self.agent = agent
        self.days = days
        self.hour = hour
        self.minute = minute
        self.since = since
    }

    /// The latest time a run was due after `since`, up to `now`. Several missed days owe a single run.
    public func owed(at now: Date, calendar: Calendar = .current) -> Date? {
        if let once { return once <= now && once > since ? once : nil }
        for back in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now), let due = time(on: day, calendar), due <= now else { continue }
            guard runs(on: due, calendar) else { continue }
            return due > since ? due : nil
        }
        return nil
    }

    /// The first time it's due after `date`.
    public func next(after date: Date, calendar: Calendar = .current) -> Date {
        if let once { return once }
        for ahead in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: ahead, to: date), let due = time(on: day, calendar), due > date,
                  runs(on: due, calendar) else { continue }
            return due
        }
        return date
    }

    /// The last run started more than a few minutes after it was due, because the Mac slept or Farol was closed.
    public var startedLate: Bool { lastDue.map { since.timeIntervalSince($0) > 5 * 60 } ?? false }

    /// Like "every day at 9:00", for the sidebar.
    public var rule: String {
        if let once { return once.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) }
        return "\(days.label.lowercased()) at \(Self.clock(hour: hour, minute: minute))"
    }

    /// When it next runs, short enough for the right of a row: 9:00 today, then tmrw 9:00, Mon 9:00 or 12 Nov 9:00.
    public func upcoming(at now: Date, calendar: Calendar = .current) -> String {
        let next = next(after: now, calendar: calendar)
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = calendar.timeZone
        let time = next.formatted(style)
        if calendar.isDate(next, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(next, inSameDayAs: tomorrow) { return "tmrw \(time)" }
        var day = next < calendar.date(byAdding: .day, value: 7, to: now)! ? Date.FormatStyle().weekday(.abbreviated) : Date.FormatStyle().day().month(.abbreviated)
        day.timeZone = calendar.timeZone
        return "\(next.formatted(day)) \(time)"
    }

    /// The time of day in the user's own format, 9:00 or 9:00 AM.
    public static func clock(hour: Int, minute: Int, calendar: Calendar = .current) -> String {
        let date = calendar.date(from: DateComponents(hour: hour, minute: minute)) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// Minutes into the day for a time typed any common way: 9, 905, 9:05, 9.05, 21h30, 9pm or 9:05 AM.
    public static func minutes(typed: String) -> Int? {
        var text = typed.lowercased().filter { !$0.isWhitespace }
        let half = ["am", "pm", "a", "p"].first { text.hasSuffix($0) }
        if let half { text.removeLast(half.count) }
        let parts = text.split(omittingEmptySubsequences: false) { ":.h".contains($0) }.map(String.init)
        guard parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }), !(parts.first ?? "").isEmpty else { return nil }
        var hour: Int?, minute: Int?
        switch parts.count {
        case 1 where parts[0].count <= 2: (hour, minute) = (Int(parts[0]), 0)
        case 1 where parts[0].count <= 4: (hour, minute) = (Int(parts[0].dropLast(2)), Int(parts[0].suffix(2)))
        case 2 where parts[1].count <= 2: (hour, minute) = (Int(parts[0]), parts[1].isEmpty ? 0 : Int(parts[1]))
        default: return nil
        }
        guard var hour, let minute, minute < 60 else { return nil }
        if let half {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (half.hasPrefix("p") ? 12 : 0)
        }
        return hour < 24 ? hour * 60 + minute : nil
    }

    /// The branch of a run started on `day`.
    public func branch(on day: Date, calendar: Calendar = .current) -> String {
        if once != nil { return branch }
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%@-%04d-%02d-%02d", branch, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func time(on day: Date, _ calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    private func runs(on day: Date, _ calendar: Calendar) -> Bool {
        days == .everyDay || !calendar.isDateInWeekend(day)
    }
}
