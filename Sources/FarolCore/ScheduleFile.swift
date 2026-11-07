import Foundation

/// A task as a Markdown file in `~/.farol/schedules`, so you, your editor or an agent can read and write one.
/// The front matter says when and where, the body is the prompt, as the Farol skill shows. What Farol learns as it runs stays out of the file.
public enum ScheduleFile {
    public static let folder = FarolHome.url.appendingPathComponent("schedules")

    /// English day names, the same on every Mac, so a file reads the same wherever it's synced.
    private static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    public enum Problem: Error, CustomStringConvertible, Equatable {
        case noFrontMatter, missing(String), unreadable(String, String)

        public var description: String {
            switch self {
            case .noFrontMatter: "It doesn't start with front matter between two --- lines."
            case .missing(let key): "It has no \(key)."
            case .unreadable(let key, let value): "Its \(key) \"\(value)\" isn't one Farol can read."
            }
        }
    }

    /// The task in `text`, with its file's name as its id. State like paused or past runs comes from elsewhere.
    public static func parse(_ text: String, id: String, home: String = NSHomeDirectory()) throws -> Schedule {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw Problem.noFrontMatter
        }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let prompt = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw Problem.missing("prompt under the front matter") }
        guard let when = fields["when"], !when.isEmpty else { throw Problem.missing("when") }
        let expand = { (path: String) in path.hasPrefix("~/") ? home + path.dropFirst() : path }
        let repos = (fields["repos"] ?? fields["repo"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(expand)
        guard !repos.isEmpty else { throw Problem.missing("repos") }
        guard let rule = Self.when(when) else { throw Problem.unreadable("when", when) }
        let branch = fields["branch"].flatMap { $0.isEmpty ? nil : $0 } ?? id
        var schedule = Schedule(name: fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? prompt.components(separatedBy: "\n")[0],
                                task: prompt, repos: repos, branch: branch, agent: expand(fields["agent"] ?? ""),
                                weekdays: rule.weekdays, hour: rule.minutes / 60, minute: rule.minutes % 60, since: .distantPast)
        schedule.id = id
        schedule.once = rule.once
        return schedule
    }

    /// The file for `schedule`, in the shape `parse` reads.
    public static func text(for schedule: Schedule, home: String = NSHomeDirectory(), calendar: Calendar = .current) -> String {
        let tilde = { (path: String) in path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path }
        let repos = schedule.repos.map(tilde)
        return """
        ---
        name: \(schedule.name)
        when: \(when(of: schedule, calendar: calendar))
        repos: \(repos.joined(separator: ", "))
        branch: \(schedule.branch)
        agent: \(tilde(schedule.agent))
        ---
        \(schedule.task)

        """
    }

    /// A file name for a new task that no other file has, from its branch.
    public static func name(for schedule: Schedule, taken: (String) -> Bool) -> String {
        let base = schedule.branch.replacingOccurrences(of: "/", with: "-")
        var name = base
        var number = 2
        while taken(name) {
            name = "\(base)-\(number)"
            number += 1
        }
        return name
    }

    /// `once 2026-11-12 14:30`, `every day 9:00`, `weekdays 9:00` or days by name like `mon, thu 9:00`.
    static func when(_ text: String) -> (weekdays: Set<Int>, minutes: Int, once: Date?)? {
        var words = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        // 9:00 am arrives as two words.
        if let last = words.last, ["am", "pm"].contains(last), words.count > 1 { words[words.count - 2] += words.removeLast() }
        guard let time = words.last, let minutes = Schedule.minutes(typed: time) else { return nil }
        let days = Array(words.dropLast())
        if days.first == "once" {
            guard days.count == 2 else { return nil }
            let parts = days[1].split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, let date = Calendar.current.date(from: DateComponents(
                year: parts[0], month: parts[1], day: parts[2], hour: minutes / 60, minute: minutes % 60)) else { return nil }
            return (Schedule.everyDay, minutes, date)
        }
        switch days {
        case ["every", "day"], ["daily"], []: return (Schedule.everyDay, minutes, nil)
        case ["weekdays"]: return (Schedule.workweek, minutes, nil)
        default:
            let picked = days.map { day in dayNames.firstIndex { day.hasPrefix($0) }.map { $0 + 1 } }
            guard !picked.contains(nil) else { return nil }
            return (Set(picked.compactMap { $0 }), minutes, nil)
        }
    }

    private static func when(of schedule: Schedule, calendar: Calendar) -> String {
        if let once = schedule.once {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: once)
            return String(format: "once %04d-%02d-%02d %d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
                          parts.minute ?? 0)
        }
        let time = String(format: "%d:%02d", schedule.hour, schedule.minute)
        if schedule.weekdays == Schedule.everyDay { return "every day \(time)" }
        if schedule.weekdays == Schedule.workweek { return "weekdays \(time)" }
        return (1...7).filter(schedule.weekdays.contains).map { dayNames[$0 - 1] }.joined(separator: ", ") + " \(time)"
    }
}
