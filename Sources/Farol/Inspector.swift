import AppKit
import Darwin
import FarolCore
import os
import SwiftUI

/// ⌥⌘I, the Farol Inspector: what Farol spends, to see whether a change made it slower.
/// Its samplers only run while it's open, and it reads what Perf recorded once a second, so watching costs next to nothing.
final class Inspector: NSObject, NSWindowDelegate {
    static let shared = Inspector()

    private var panel: NSPanel?
    private let monitor = InspectorMonitor()

    func toggle() {
        if let panel, panel.isVisible { return panel.close() }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        monitor.start()
        panel.orderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        monitor.stop()
    }

    private func makePanel() -> NSPanel {
        // A HUD that never takes focus, so the terminal you are watching keeps it.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: InspectorView.width, height: 400),
                            styleMask: [.titled, .closable, .hudWindow, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.title = "Farol Inspector"
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: InspectorView(monitor: monitor))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - InspectorView.width - 20, y: screen.maxY - 20))
        }
        return panel
    }
}

/// One thing the inspector measures, said so anyone can tell whether it's fine.
struct Reading {
    enum Level: Int, Comparable {
        case good, worthALook, problem

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var word: String {
            switch self {
            case .good: "fine"
            case .worthALook: "worth a look"
            case .problem: "problem"
            }
        }
    }

    let title: String
    let value: String
    /// What the number means and what good looks like, for someone seeing it the first time.
    let caption: String
    let level: Level
    /// The runs behind a bad number, so it says where to look.
    var details: [String] = []
}

/// Samples while the inspector is open: Perf's snapshot, memory and CPU once a second, and how late the main thread answers.
final class InspectorMonitor: ObservableObject {
    struct Stall {
        let at: Date
        let duration: TimeInterval
    }

    @Published private(set) var snapshot = Perf.shared.snapshot()
    @Published private(set) var memory: UInt64 = 0
    @Published private(set) var cpu: Double = 0
    /// Main thread delays over `stallAbove`, from the last minute.
    @Published private(set) var stalls: [Stall] = []

    /// A delay a person feels when typing.
    static let stallAbove: TimeInterval = 0.1
    /// What the command rate and the slowest commands cover.
    static let window: TimeInterval = 10

    private var timer: Timer?
    private var pinger: DispatchSourceTimer?
    private var lastCPU: (time: TimeInterval, at: Date)?

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        // A ping every 50 ms from another thread. However late the main thread runs it is how long it was busy.
        // One at a time, so a long freeze counts once, at its full length, rather than once per ping queued behind it.
        let waiting = OSAllocatedUnfairLock(initialState: false)
        let pinger = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        pinger.schedule(deadline: .now(), repeating: .milliseconds(50))
        pinger.setEventHandler { [weak self] in
            guard waiting.withLock({ busy in defer { busy = true }; return !busy }) else { return }
            let sent = Date()
            DispatchQueue.main.async {
                waiting.withLock { $0 = false }
                self?.answered(sent)
            }
        }
        pinger.resume()
        self.pinger = pinger
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pinger?.cancel()
        pinger = nil
        lastCPU = nil
    }

    private func answered(_ sent: Date) {
        let delay = Date().timeIntervalSince(sent)
        guard delay > Self.stallAbove else { return }
        stalls.append(Stall(at: sent, duration: delay))
    }

    private func sample() {
        snapshot = Perf.shared.snapshot()
        memory = Self.footprint()
        let now = Date()
        let used = Self.cpuTime()
        if let last = lastCPU { cpu = (used - last.time) / now.timeIntervalSince(last.at) * 100 }
        lastCPU = (used, now)
        stalls.removeAll { $0.at < now.addingTimeInterval(-60) }
    }

    /// The memory Activity Monitor shows for Farol.
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Seconds of CPU Farol itself has used, not the commands it starts.
    private static func cpuTime() -> TimeInterval {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = { (time: timeval) in TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    // MARK: Readings

    /// What the panel and the copied report both show, so they never disagree.
    func readings(at now: Date) -> [Reading] {
        let rates = snapshot.rate(over: Self.window, at: now)
        let rate = rates.values.reduce(0, +)
        let tools = rates.sorted { $0.value > $1.value }.map { "\($0.key) \(Self.decimal($0.value))" }
        let longest = stalls.map(\.duration).max() ?? 0
        let onMain = snapshot.recent.filter(\.onMain).prefix(3)
        return [
            Reading(
                title: "Commands",
                value: rate == 0 ? "None" : "\(Self.decimal(rate)) a second" + (tools.isEmpty ? "" : ", " + tools.joined(separator: ", ")),
                caption: "git, gh and glab runs in the last \(Int(Self.window)) seconds. Under 2 a second is calm.",
                // An agent at work keeps git busy, but #159 showed 10 a second is a loop, not work.
                level: rate < 2 ? .good : rate < 5 ? .worthALook : .problem),
            Reading(
                title: "Git on the main thread",
                value: snapshot.onMain == 0 ? "None" : "\(snapshot.onMain) since launch",
                caption: "Each run freezes the window until it ends. It should stay at none.",
                level: snapshot.onMain == 0 ? .good : .problem,
                details: onMain.map { "\($0.command), \(Self.ms($0.duration)), \(Self.ago($0.start, now: now))" }),
            Reading(
                title: "Window freezes",
                value: stalls.isEmpty ? "None" : "\(stalls.count), the longest \(Self.ms(longest))",
                caption: "Times in the last minute the window couldn't answer for over \(Self.ms(Self.stallAbove)).",
                // A quarter second is where a pause turns into a stutter you notice while typing.
                level: stalls.isEmpty ? .good : longest < 0.25 ? .worthALook : .problem),
            Reading(
                title: "Memory",
                value: Self.size(memory),
                caption: "What Activity Monitor shows for Farol, terminals included.",
                level: memory < 1 << 30 ? .good : memory < 2 << 30 ? .worthALook : .problem),
            Reading(
                title: "CPU",
                value: "\(Int(cpu.rounded()))%",
                caption: "Farol itself, not the commands it starts. Near 0 while idle.",
                level: cpu < 25 ? .good : cpu < 75 ? .worthALook : .problem),
        ]
    }

    /// The panel as text, to paste into a pull request as a before or after.
    func report(at now: Date) -> String {
        var lines = ["Farol Inspector, \(now.formatted(date: .abbreviated, time: .shortened))"]
        for reading in readings(at: now) {
            lines.append("\(reading.title): \(reading.value) (\(reading.level.word))")
            lines += reading.details.map { "    \($0)" }
        }
        let slowest = snapshot.slowest(5, over: Self.window, at: now)
        if !slowest.isEmpty {
            lines.append("Slowest commands, last \(Int(Self.window)) seconds:")
            lines += slowest.map { "    " + Self.ms($0.duration).leftPadded(to: 7) + "  " + $0.command }
        }
        lines.append("\(snapshot.total) commands since launch")
        return lines.joined(separator: "\n")
    }

    static func ms(_ seconds: TimeInterval) -> String { "\(Int((seconds * 1000).rounded())) ms" }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        return seconds < 60 ? "\(seconds) s ago" : "\(seconds / 60) min ago"
    }

    private static func decimal(_ value: Double) -> String { String(format: "%.1f", value) }

    private static func size(_ bytes: UInt64) -> String {
        bytes < 1 << 30 ? "\(bytes >> 20) MB" : String(format: "%.1f GB", Double(bytes) / Double(1 << 30))
    }
}

private struct InspectorView: View {
    static let width: CGFloat = 380

    @ObservedObject var monitor: InspectorMonitor
    @State private var copied = false

    var body: some View {
        let now = Date()
        let readings = monitor.readings(at: now)
        VStack(alignment: .leading, spacing: 14) {
            summary(readings)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(readings, id: \.title) { reading in row(reading) }
            }
            Divider()
            slowest(now)
            footer(now)
        }
        .padding(16)
        .frame(width: Self.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The first glance: is anything wrong, and if so what.
    private func summary(_ readings: [Reading]) -> some View {
        let worst = readings.map(\.level).max() ?? .good
        let named = readings.filter { $0.level == worst }.map(\.title).joined(separator: ", ")
        let text = switch worst {
        case .good: "Everything looks healthy"
        case .worthALook: "Worth a look: \(named)"
        case .problem: "Needs attention: \(named)"
        }
        return HStack(spacing: 8) {
            Dot(level: worst, size: 10)
            Text(text).font(.system(size: 13, weight: .semibold))
        }
    }

    private func row(_ reading: Reading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Dot(level: reading.level, size: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(reading.title).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 12)
                    // Color only when it needs attention. The dot already says a value is fine.
                    Text(reading.value).font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(reading.level == .good ? .primary : Dot.color(reading.level))
                        .lineLimit(1)
                }
                Text(reading.caption).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(reading.details, id: \.self) { detail in
                    Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Dot.color(reading.level))
                        .lineLimit(1)
                }
            }
        }
    }

    private func slowest(_ now: Date) -> some View {
        let runs = monitor.snapshot.slowest(5, over: InspectorMonitor.window, at: now)
        return VStack(alignment: .leading, spacing: 5) {
            Text("Slowest commands, last \(Int(InspectorMonitor.window)) seconds").font(.system(size: 12, weight: .medium))
            if runs.isEmpty {
                Text("Nothing ran").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                HStack(spacing: 10) {
                    Text(InspectorMonitor.ms(run.duration)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                    Text(run.command).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 11))
            }
        }
    }

    private func footer(_ now: Date) -> some View {
        HStack {
            Text("\(monitor.snapshot.total) commands since launch").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button(copied ? "Copied" : "Copy Report") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(monitor.report(at: now), forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .help("The readings as text, to paste into a pull request as a before or after")
        }
    }
}

private struct Dot: View {
    let level: Reading.Level
    let size: CGFloat

    var body: some View {
        Circle().fill(Self.color(level)).frame(width: size, height: size)
    }

    static func color(_ level: Reading.Level) -> Color {
        switch level {
        case .good: .green
        case .worthALook: .orange
        case .problem: .red
        }
    }
}

private extension String {
    func leftPadded(to width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}
