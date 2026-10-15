import AppKit
import Darwin
import os
import FarolCore
import SwiftUI

/// ⌥⌘I: what Farol spends, to see whether a change made it slower. Outside commands, stalls of the main thread, memory and CPU.
/// Its samplers only run while it's open, and it reads what Perf recorded once a second, so watching costs next to nothing.
final class DeveloperPanel: NSObject, NSWindowDelegate {
    static let shared = DeveloperPanel()

    private var panel: NSPanel?
    private let monitor = PerfMonitor()

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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                            styleMask: [.titled, .closable, .hudWindow, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.title = "Developer"
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: DeveloperView(monitor: monitor))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 360, y: screen.maxY - 20))
        }
        return panel
    }
}

/// Samples while the panel is open: Perf's snapshot, memory and CPU once a second, and how late the main thread answers.
final class PerfMonitor: ObservableObject {
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
    /// What rates and the slowest runs cover.
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

    /// The panel as text, to paste into a pull request's Checked section as a before or after.
    var report: String {
        let now = Date()
        var lines = [
            "Commands: \(Self.rate(snapshot.rate(over: Self.window, at: now)))",
            "On the main thread: \(snapshot.onMain) since launch"
                + snapshot.recent.filter(\.onMain).prefix(3).map { ", \($0.command) \(Self.ms($0.duration))" }.joined(),
            "Stalls over \(Int(Self.stallAbove * 1000)) ms: \(stalls.count) in the last minute, longest \(Self.ms(stalls.map(\.duration).max() ?? 0))",
            "Memory: \(Self.megabytes(memory))   CPU: \(Int(cpu.rounded()))%",
            "Slowest over \(Int(Self.window)) s:",
        ]
        lines += snapshot.slowest(5, over: Self.window, at: now).map { "  \(Self.ms($0.duration))  \($0.command)" }
        return lines.joined(separator: "\n")
    }

    static func rate(_ rates: [String: Double]) -> String {
        let total = rates.values.reduce(0, +)
        let tools = rates.sorted { $0.value > $1.value }.map { "\($0.key) \(String(format: "%.1f", $0.value))" }
        return ([String(format: "%.1f/s", total)] + tools).joined(separator: "  ")
    }

    static func ms(_ seconds: TimeInterval) -> String { "\(Int((seconds * 1000).rounded())) ms" }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        return seconds < 60 ? "\(seconds) s ago" : "\(seconds / 60) min ago"
    }

    static func megabytes(_ bytes: UInt64) -> String { "\(bytes / 1_048_576) MB" }
}

private struct DeveloperView: View {
    @ObservedObject var monitor: PerfMonitor

    var body: some View {
        let now = Date()
        let snapshot = monitor.snapshot
        let longest = monitor.stalls.map(\.duration).max() ?? 0
        VStack(alignment: .leading, spacing: 8) {
            row("Commands", PerfMonitor.rate(snapshot.rate(over: PerfMonitor.window, at: now)))
            // Git on the main thread freezes the window, so any at all is worth fixing.
            row("On main thread", "\(snapshot.onMain)", alarm: snapshot.onMain > 0)
            // The count alone says something is wrong. Which commands says where to look.
            ForEach(Array(snapshot.recent.filter(\.onMain).prefix(3).enumerated()), id: \.offset) { _, run in
                Text("\(run.command)  \(PerfMonitor.ms(run.duration))  \(PerfMonitor.ago(run.start, now: now))")
                    .foregroundStyle(.red).padding(.leading, 110).lineLimit(1)
            }
            row("Stalls, 1 min", monitor.stalls.isEmpty ? "none" : "\(monitor.stalls.count), longest \(PerfMonitor.ms(longest))",
                alarm: longest > 0.25)
            row("Memory", PerfMonitor.megabytes(monitor.memory))
            row("CPU", "\(Int(monitor.cpu.rounded()))%")
            Divider()
            Text("Slowest, \(Int(PerfMonitor.window)) s").foregroundStyle(.secondary)
            let slowest = snapshot.slowest(5, over: PerfMonitor.window, at: now)
            if slowest.isEmpty { Text("Nothing ran").foregroundStyle(.secondary) }
            ForEach(Array(slowest.enumerated()), id: \.offset) { _, run in
                HStack(spacing: 8) {
                    Text(PerfMonitor.ms(run.duration)).frame(width: 60, alignment: .trailing)
                    Text(run.command).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text("\(snapshot.total) commands since launch").foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(monitor.report, forType: .string)
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(12)
        .frame(width: 340, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ name: String, _ value: String, alarm: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).foregroundStyle(alarm ? .red : .primary).lineLimit(1)
        }
    }
}
