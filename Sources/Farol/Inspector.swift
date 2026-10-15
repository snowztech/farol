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
        let section: String
        let title: String
        let value: String
        /// Quieter context beside the value, like which tools ran.
        var note = ""
        /// What the reading is and what normal looks like, in a line. Shown on a click.
        let meaning: String
        var level = Perf.Level.good
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

    /// Perf watches for freezes from launch, so only the snapshot, memory and CPU are read here, once a second.
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
        let started = snapshot.started(over: Self.window, at: now)
        let count = started.values.reduce(0, +)
        let tools = started.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
        let blocking = snapshot.blocking
        let hangs = snapshot.hangs
        let longestHang = hangs.map(\.duration).max() ?? 0
        return [
            Inspector.Reading(
                section: "Processes", title: "Started", value: "\(count)",
                note: (["in \(Int(Self.window)) s"] + tools).joined(separator: " · "),
                meaning: "git, gh and glab runs in the last \(Int(Self.window)) s. Bursts are normal. A minute above 4/s means a loop.",
                level: snapshot.processLevel(at: now)),
            // What you feel first, then what causes it, so the two read as effect and cause.
            Inspector.Reading(
                section: "Responsiveness", title: "Freezes", value: hangs.isEmpty ? "none" : "\(hangs.count)",
                note: hangs.count < 2 ? "" : "longest \(Self.ms(longestHang))",
                meaning: "Times since launch the window stopped responding for 250 ms or more, whatever the cause.",
                level: snapshot.hangLevel,
                details: hangs.prefix(3).map { "\(Self.ms($0.duration)) · \(Self.ago($0.start, now: now))" }),
            Inspector.Reading(
                section: "Responsiveness", title: "Blocking processes", value: blocking.isEmpty ? "none" : "\(snapshot.onMain)",
                meaning: "git, gh or glab run where the window is drawn. Each pauses it, even too briefly to notice. Should be none.",
                level: snapshot.blockingLevel,
                details: blocking.prefix(3).map { "\($0.command) · \(Self.ms($0.duration)) · \(Self.ago($0.start, now: now))" }),
            Inspector.Reading(
                section: "Resources", title: "Memory", value: Self.size(memory.now), note: "peak \(Self.size(memory.peak))",
                meaning: "Farol's memory now, and its most since launch. A peak that keeps climbing is a leak.",
                level: Perf.memoryLevel(memory.now)),
            Inspector.Reading(
                section: "Resources", title: "CPU", value: "\(Int(cpu.rounded()))%",
                meaning: "Farol's own processor use. Near 0 when idle.",
                level: Perf.cpuLevel(cpu)),
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
            let verdict = switch reading.level {
            case .good: ""
            case .worthALook: "  (worth a look)"
            case .problem: "  (problem)"
            }
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
        Explained(meaning: reading.meaning, palette: p) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(reading.title).foregroundStyle(p.muted).frame(width: 124, alignment: .leading)
                    Text(reading.value).monospacedDigit().foregroundStyle(color(reading.level, p))
                    if !reading.note.isEmpty {
                        Text("   " + reading.note).foregroundStyle(p.muted).lineLimit(1)
                    }
                }
                ForEach(reading.details, id: \.self) { detail in
                    Text(detail).foregroundStyle(p.muted).padding(.leading, 124).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private func longest(_ now: Date, _ p: Palette) -> some View {
        let runs = monitor.snapshot.longest(5, over: InspectorMonitor.recent, at: now)
        let meaning = "The slowest runs of the last minute. git takes 10–100 ms, gh and glab up to 2 s."
        return Explained(meaning: meaning, palette: p) {
            VStack(alignment: .leading, spacing: 6) {
                header("Longest processes", span: "last minute", p)
                if runs.isEmpty { Text("none").foregroundStyle(p.muted) }
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    HStack(spacing: 0) {
                        Text(InspectorMonitor.ms(run.duration)).monospacedDigit()
                            .foregroundStyle(InspectorMonitor.isLong(run) ? p.waiting : p.muted)
                            .frame(width: 112, alignment: .leading)
                        Text(run.command).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                            .padding(.leading, 12)
                    }
                }
            }
        }
    }

    /// The theme's own colors: plain text when fine, its yellow to look at, its red for a problem.
    private func color(_ level: Perf.Level, _ p: Palette) -> Color {
        switch level {
        case .good: p.text
        case .worthALook: p.waiting
        case .problem: p.removed
        }
    }
}

/// A part of the inspector that says what it means on a click. A light background and the hand on hover show it can.
/// Inline rather than a tooltip, since the inspector never takes focus and a sentence or two needs room to wrap.
private struct Explained<Content: View>: View {
    let meaning: String
    let palette: Palette
    @ViewBuilder let content: Content

    @State private var open = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            if open {
                Text(meaning).font(.system(size: 11)).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? palette.raised : open ? palette.surface : .clear))
        // The highlight reaches past the text, so the text stays lined up with the section titles.
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onClickableHover { hovering = $0 }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }
    }
}

private extension String {
    func leftPadded(to width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}
