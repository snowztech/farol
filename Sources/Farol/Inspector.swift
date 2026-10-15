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
        // A utility window in the theme's colors that never takes focus, so the terminal you are watching keeps it.
        // About what the readings need, so there's no empty band below them when things are quiet.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.title = "Farol Inspector"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 300, height: 260)
        panel.setFrameAutosaveName("FarolInspector")
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: InspectorView(monitor: monitor, state: state))
        // The first time only. After that it opens where you left it.
        if !panel.setFrameUsingName("FarolInspector"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 360, y: screen.maxY - 20))
        }
        return panel
    }
}

extension Inspector {
    /// One thing the inspector measures.
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

        let section: String
        let title: String
        let value: String
        /// Quieter context beside the value, like which tools ran.
        var note = ""
        /// What the number means and what good looks like, shown on hover.
        let help: String
        var level = Level.good
        /// The runs behind a value that needs a look, so it says where to look.
        var details: [String] = []
    }
}

/// Samples while the inspector is open: Perf's snapshot, memory and CPU once a second, and how late the main thread answers.
final class InspectorMonitor: ObservableObject {
    @Published private(set) var snapshot = Perf.shared.snapshot()
    @Published private(set) var memory: (now: UInt64, peak: UInt64) = (0, 0)
    @Published private(set) var cpu: Double = 0

    /// What the process rate covers: how busy Farol is right now.
    static let window: TimeInterval = 10
    /// What the longest processes cover: long enough to still show a burst once things go quiet.
    static let recent: TimeInterval = 60

    private var timer: Timer?
    private var lastCPU: (time: TimeInterval, at: Date)?

    /// Hangs are watched from launch by Perf, so only the snapshot, memory and CPU are read here, once a second.
    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastCPU = nil
    }

    private func sample() {
        snapshot = Perf.shared.snapshot()
        memory = Self.footprint()
        let now = Date()
        let used = Self.cpuTime()
        if let last = lastCPU { cpu = (used - last.time) / now.timeIntervalSince(last.at) * 100 }
        lastCPU = (used, now)
    }

    /// The memory Activity Monitor shows for Farol, and the most it has used since launch, which macOS keeps anyway.
    private static func footprint() -> (now: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak)) : (0, 0)
    }

    /// Seconds of CPU Farol itself has used, not the processes it starts.
    private static func cpuTime() -> TimeInterval {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = { (time: timeval) in TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    // MARK: Readings

    /// What the window and the copied report both show, so they never disagree.
    func readings(at now: Date) -> [Inspector.Reading] {
        let rates = snapshot.rate(over: Self.window, at: now)
        let rate = rates.values.reduce(0, +)
        let tools = rates.sorted { $0.value > $1.value }.map { "\($0.key) \(Self.decimal($0.value))" }
        let blocking = snapshot.blocking
        let hangs = snapshot.hangs
        let longestHang = hangs.map(\.duration).max() ?? 0
        return [
            Inspector.Reading(
                section: "Processes", title: "Rate", value: rate == 0 ? "0/s" : "\(Self.decimal(rate))/s", note: tools.joined(separator: " · "),
                help: "git, gh and glab processes started a second, over the last \(Int(Self.window)) seconds. Under 2 is calm. A launch or a push starts more for a moment.",
                // An agent at work keeps git busy, but #159 showed 10 a second is a loop, not work.
                level: rate < 2 ? .good : rate < 5 ? .worthALook : .problem),
            Inspector.Reading(
                section: "Main thread", title: "Blocking runs", value: blocking.isEmpty ? "none" : "\(snapshot.onMain)",
                help: "Processes run on the main thread since launch. The window can't redraw or answer until each one ends, so there should be none.",
                // Under 100 ms nobody feels it, but it breaks the rule and a slow disk would turn it into a hang.
                level: blocking.isEmpty ? .good : blocking.contains { $0.duration >= 0.1 } ? .problem : .worthALook,
                details: blocking.prefix(3).map { "\($0.command) · \(Self.ms($0.duration)) · \(Self.ago($0.start, now: now))" }),
            Inspector.Reading(
                section: "Main thread", title: "Hangs", value: hangs.isEmpty ? "none" : "\(hangs.count)",
                note: hangs.count < 2 ? "" : "longest \(Self.ms(longestHang))",
                help: "Times since launch the window didn't answer for 250 ms or more, Apple's measure of a hang. Watched even while the inspector is closed.",
                level: hangs.isEmpty ? .good : longestHang < 1 ? .worthALook : .problem,
                details: hangs.prefix(3).map { "\(Self.ms($0.duration)) · \(Self.ago($0.start, now: now))" }),
            Inspector.Reading(
                section: "Resources", title: "Memory", value: Self.size(memory.now), note: "peak \(Self.size(memory.peak))",
                help: "What Activity Monitor shows for Farol, terminals included, and the most it has used since launch. A peak that keeps climbing is a leak.",
                level: memory.now < 1 << 30 ? .good : memory.now < 2 << 30 ? .worthALook : .problem),
            Inspector.Reading(
                section: "Resources", title: "CPU", value: "\(Int(cpu.rounded()))%",
                help: "Farol itself, not the processes it starts. Near 0 while idle.",
                level: cpu < 25 ? .good : cpu < 75 ? .worthALook : .problem),
        ]
    }

    /// The readings as text, to paste into a pull request as a before or after.
    func report(at now: Date) -> String {
        var lines = ["Farol Inspector, \(now.formatted(date: .abbreviated, time: .shortened))"]
        var section = ""
        for reading in readings(at: now) {
            if reading.section != section {
                section = reading.section
                lines.append(section)
            }
            let note = reading.note.isEmpty ? "" : "  \(reading.note)"
            let verdict = reading.level == .good ? "" : "  (\(reading.level.word))"
            lines.append("  " + reading.title.padding(toLength: 15, withPad: " ", startingAt: 0) + reading.value + note + verdict)
            lines += reading.details.map { "    \($0)" }
        }
        let longest = snapshot.longest(5, over: Self.recent, at: now)
        if !longest.isEmpty {
            lines.append("Longest processes, last minute")
            lines += longest.map { "  " + Self.ms($0.duration).leftPadded(to: 8) + "  " + $0.command }
        }
        lines.append("\(snapshot.total) processes since launch")
        return lines.joined(separator: "\n")
    }

    /// Long for its kind: git works on the disk, gh and glab go over the network.
    static func isLong(_ run: Perf.Run) -> Bool {
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

/// Quiet like the rest of Farol: sections of muted labels and plain values, color only on a value that needs a look.
private struct InspectorView: View {
    @ObservedObject var monitor: InspectorMonitor
    @ObservedObject var state: WindowState
    @State private var copied = false

    var body: some View {
        let p = state.palette
        let now = Date()
        let readings = monitor.readings(at: now)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.sections(of: readings), id: \.self) { section in
                        VStack(alignment: .leading, spacing: 7) {
                            header(section, p)
                            ForEach(readings.filter { $0.section == section }, id: \.title) { row($0, p) }
                        }
                    }
                    longest(now, p)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(p.line).frame(height: 1)
            HStack {
                Text("\(monitor.snapshot.total) processes since launch").foregroundStyle(p.muted)
                Spacer()
                Button(copied ? "Copied" : "Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(monitor.report(at: now), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? p.text : p.muted)
                .help("The readings as text, to paste into a pull request as a before or after")
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(p.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The content starts below the title bar, and the theme's color reaches under it.
        .background(p.background.ignoresSafeArea())
    }

    private static func sections(of readings: [Inspector.Reading]) -> [String] {
        readings.reduce(into: []) { sections, reading in
            if sections.last != reading.section { sections.append(reading.section) }
        }
    }

    /// Small capitals, as the sidebar and the graph title their parts.
    private func header(_ title: String, span: String = "", _ p: Palette) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6)
            if !span.isEmpty { Text(span).font(.system(size: 10)) }
        }
        .foregroundStyle(p.muted)
    }

    private func row(_ reading: Inspector.Reading, _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(reading.title).foregroundStyle(p.muted).frame(width: 104, alignment: .leading)
                Text(reading.value).monospacedDigit().foregroundStyle(color(reading.level, p))
                if !reading.note.isEmpty {
                    Text("   " + reading.note).foregroundStyle(p.muted).lineLimit(1)
                }
            }
            ForEach(reading.details, id: \.self) { detail in
                Text(detail).foregroundStyle(p.muted).padding(.leading, 104).lineLimit(1).truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
        .help(reading.help)
    }

    private func longest(_ now: Date, _ p: Palette) -> some View {
        let runs = monitor.snapshot.longest(5, over: InspectorMonitor.recent, at: now)
        return VStack(alignment: .leading, spacing: 6) {
            header("Longest processes", span: "last minute", p)
                .help("The processes that took longest lately. Each one takes some time, so only one long for its kind gets a color.")
            if runs.isEmpty { Text("none").foregroundStyle(p.muted) }
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                HStack(spacing: 0) {
                    Text(InspectorMonitor.ms(run.duration)).monospacedDigit()
                        .foregroundStyle(InspectorMonitor.isLong(run) ? p.waiting : p.muted)
                        .frame(width: 92, alignment: .leading)
                    Text(run.command).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                        .padding(.leading, 12)
                }
            }
        }
    }

    /// The theme's own colors: plain text when fine, its yellow to look at, its red for a problem.
    private func color(_ level: Inspector.Reading.Level, _ p: Palette) -> Color {
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
