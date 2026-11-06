import Foundation

/// A launchd job that opens Farol at each task's time, so a task still runs after Farol was quit.
/// Farol's own scheduler decides what runs once it's open. launchd only gets it there.
public enum LaunchAgent {
    /// launchd's `StartCalendarInterval` entries for the tasks that aren't paused. launchd counts weekdays from Sunday as 0.
    public static func times(for schedules: [Schedule], calendar: Calendar = .current) -> [[String: Int]] {
        schedules.filter { !$0.paused }.flatMap { schedule -> [[String: Int]] in
            if let once = schedule.once {
                let day = calendar.dateComponents([.month, .day, .hour, .minute], from: once)
                return [["Month": day.month ?? 1, "Day": day.day ?? 1, "Hour": day.hour ?? 0, "Minute": day.minute ?? 0]]
            }
            let time = ["Hour": schedule.hour, "Minute": schedule.minute]
            guard schedule.days == .weekdays else { return [time] }
            return (1...5).map { time.merging(["Weekday": $0]) { $1 } }
        }
    }

    /// The job's plist, or nil when no task needs Farol opened.
    public static func plist(label: String, bundle: String, schedules: [Schedule], calendar: Calendar = .current) -> Data? {
        let times = times(for: schedules, calendar: calendar)
        guard !times.isEmpty else { return nil }
        // `-g` keeps Farol behind whatever you're doing. If it's already open this does nothing.
        let job: [String: Any] = ["Label": label, "ProgramArguments": ["/usr/bin/open", "-g", "-b", bundle], "StartCalendarInterval": times]
        return try? PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }

    private static let queue = DispatchQueue(label: "farol.launch-agent")

    /// Writes and loads the job, or removes it once no task is left. launchd only rereads a plist when it's loaded again.
    public static func sync(_ schedules: [Schedule], bundle: String) {
        let label = "\(bundle).tasks"
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let data = plist(label: label, bundle: bundle, schedules: schedules)
        queue.async {
            guard data != (try? Data(contentsOf: file)) else { return }
            let domain = "gui/\(getuid())"
            _ = try? Git.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], in: "/")
            guard let data else {
                try? FileManager.default.removeItem(at: file)
                return
            }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
                try Git.run("/bin/launchctl", ["bootstrap", domain, file.path], in: "/")
            } catch {
                NSLog("Farol couldn't set up opening for tasks: \(error)")
            }
        }
    }
}
