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

    /// Opens over `window`, in its theme.
    func toggle(state: WindowState, over window: NSWindow?) {
        if let panel, panel.isVisible { return panel.close() }
        let panel = self.panel ?? makePanel(state: state)
        self.panel = panel
        panel.appearance = window?.appearance
        monitor.start()
        panel.orderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        monitor.stop()
    }

    private func makePanel(state: WindowState) -> NSPanel {
        // A small window in the theme's colors that never takes focus, so the terminal you are watching keeps it.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: InspectorView.width, height: 300),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.title = "Farol Inspector"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: InspectorView(monitor: monitor, state: state))
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
    /// Quieter context beside the value, like which tools ran.
    var note = ""
    /// What the number means and what good looks like, shown on hover.
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
        return [
            Reading(
                title: "commands", value: rate == 0 ? "none" : "\(Self.decimal(rate))/s", note: tools.joined(separator: " · "),
                caption: "git, gh and glab runs a second, over the last \(Int(Self.window)) seconds. Under 2 is calm, a launch or a push runs more.",
                // An agent at work keeps git busy, but #159 showed 10 a second is a loop, not work.
                level: rate < 2 ? .good : rate < 5 ? .worthALook : .problem),
            Reading(
                title: "main thread", value: "\(snapshot.onMain)", note: snapshot.onMain == 0 ? "" : "since launch",
                caption: "git runs on the main thread since launch. Each one freezes the window until it ends, so it should stay at 0.",
                level: snapshot.onMain == 0 ? .good : .problem,
                details: snapshot.recent.filter(\.onMain).prefix(3).map {
                    "\($0.command) · \(Self.ms($0.duration)) · \(Self.ago($0.start, now: now))"
                }),
            Reading(
                title: "freezes", value: stalls.isEmpty ? "none" : "\(stalls.count)", note: stalls.isEmpty ? "" : "longest \(Self.ms(longest))",
                caption: "Times in the last minute the window couldn't answer for over \(Self.ms(Self.stallAbove)).",
                // A quarter second is where a pause turns into a stutter you notice while typing.
                level: stalls.isEmpty ? .good : longest < 0.25 ? .worthALook : .problem),
            Reading(
                title: "memory", value: Self.size(memory),
                caption: "What Activity Monitor shows for Farol, terminals included.",
                level: memory < 1 << 30 ? .good : memory < 2 << 30 ? .worthALook : .problem),
            Reading(
                title: "cpu", value: "\(Int(cpu.rounded()))%",
                caption: "Farol itself, not the commands it starts. Near 0 while idle.",
                level: cpu < 25 ? .good : cpu < 75 ? .worthALook : .problem),
        ]
    }

    /// The panel as text, to paste into a pull request as a before or after.
    func report(at now: Date) -> String {
        var lines = ["Farol Inspector, \(now.formatted(date: .abbreviated, time: .shortened))"]
        for reading in readings(at: now) {
            let note = reading.note.isEmpty ? "" : " (\(reading.note))"
            lines.append("\(reading.title): \(reading.value)\(note), \(reading.level.word)")
            lines += reading.details.map { "    \($0)" }
        }
        let slowest = snapshot.slowest(5, over: Self.window, at: now)
        if !slowest.isEmpty {
            lines.append("longest, last \(Int(Self.window)) seconds:")
            lines += slowest.map { "    " + Self.ms($0.duration).leftPadded(to: 7) + "  " + $0.command }
        }
        lines.append("\(snapshot.total) commands since launch")
        return lines.joined(separator: "\n")
    }

    /// Slow for its kind: git works on the disk, gh and glab go over the network.
    static func isSlow(_ run: Perf.Run) -> Bool {
        run.duration > (["gh", "glab"].contains(run.tool) ? 2 : 0.3)
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

/// Quiet like the rest of Farol: muted labels, plain values, and color only on a value that needs a look.
private struct InspectorView: View {
    static let width: CGFloat = 300

    @ObservedObject var monitor: InspectorMonitor
    @ObservedObject var state: WindowState
    @State private var copied = false

    var body: some View {
        let p = state.palette
        let now = Date()
        VStack(alignment: .leading, spacing: 0) {
            // In the transparent title bar, beside the close button.
            Text("Farol Inspector").font(.system(size: 11, weight: .medium)).foregroundStyle(p.muted)
                .frame(maxWidth: .infinity).frame(height: 28)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(monitor.readings(at: now), id: \.title) { row($0, p) }
            }
            Rectangle().fill(p.line).frame(height: 1).padding(.vertical, 12)
            slowest(now, p)
            HStack {
                Text("\(monitor.snapshot.total) since launch").foregroundStyle(p.muted)
                Spacer()
                Button(copied ? "copied" : "copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(monitor.report(at: now), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? p.text : p.muted)
                .help("The readings as text, to paste into a pull request as a before or after")
            }
            .padding(.top, 12)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(p.text)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(width: Self.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(p.background)
    }

    private func row(_ reading: Reading, _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(reading.title).foregroundStyle(p.muted).frame(width: 92, alignment: .leading)
                Text(reading.value).monospacedDigit().foregroundStyle(color(reading.level, p))
                if !reading.note.isEmpty {
                    Text("  " + reading.note).foregroundStyle(p.muted).lineLimit(1)
                }
            }
            ForEach(reading.details, id: \.self) { detail in
                Text(detail).font(.system(size: 11)).foregroundStyle(p.muted).padding(.leading, 92).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .help(reading.caption)
    }

    private func slowest(_ now: Date, _ p: Palette) -> some View {
        let runs = monitor.snapshot.slowest(5, over: InspectorMonitor.window, at: now)
        return VStack(alignment: .leading, spacing: 5) {
            Text("longest · \(Int(InspectorMonitor.window)) s").foregroundStyle(p.muted)
                .help("The commands that took longest lately. Every command takes some time, so only a slow one gets a color.")
            if runs.isEmpty { Text("nothing ran").foregroundStyle(p.muted) }
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                HStack(spacing: 0) {
                    Text(InspectorMonitor.ms(run.duration)).monospacedDigit()
                        .foregroundStyle(InspectorMonitor.isSlow(run) ? p.waiting : p.muted)
                        .frame(width: 56, alignment: .trailing)
                    Text(run.command).font(.system(size: 10.5, design: .monospaced)).lineLimit(1).padding(.leading, 36)
                }
            }
        }
    }

    /// The theme's own colors: plain text when fine, its yellow to look at, its red for a problem.
    private func color(_ level: Reading.Level, _ p: Palette) -> Color {
        switch level {
        case .good: p.text
        case .worthALook: p.waiting
        case .problem: p.removed
        }
    }
}

private extension String {
    func leftPadded(to width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}
