import Foundation
import Testing
@testable import FarolCore

@Test func namesACommandByItsToolAndFirstWords() {
    #expect(Perf.command("/usr/bin/git", ["-c", "core.quotePath=false", "diff", "--no-color", "--numstat"]) == "git diff")
    #expect(Perf.command("/opt/homebrew/bin/gh", ["pr", "view", "3", "--json", "body"]) == "gh pr view")
    #expect(Perf.command("/bin/zsh", ["-ilc", "printf %s \"$PATH\""]) == "zsh")
    // A count like log's limit says nothing about which command it was.
    #expect(Perf.command("/usr/bin/git", ["log", "400", "--format=%H"]) == "git log")
}

@Test func keepsTheLastRunsAndCountsThemAll() {
    let perf = Perf(capacity: 3)
    let now = Date()
    for index in 0..<5 {
        perf.record(Perf.Run(command: "git status", tool: "git", start: now.addingTimeInterval(Double(index)),
                             duration: 0.01, onMain: index == 4))
    }
    let snapshot = perf.snapshot()
    #expect(snapshot.recent.count == 3)
    // Newest first.
    #expect(snapshot.recent.first?.start == now.addingTimeInterval(4))
    #expect(snapshot.total == 5)
    #expect(snapshot.onMain == 1)
}

@Test func ratesAndSlowestCoverOnlyTheWindow() {
    let perf = Perf()
    let now = Date()
    let run = { (tool: String, ago: TimeInterval, duration: TimeInterval) in
        perf.record(Perf.Run(command: "\(tool) x", tool: tool, start: now.addingTimeInterval(-ago), duration: duration, onMain: false))
    }
    run("git", 1, 0.02)
    run("git", 2, 0.30)
    run("gh", 3, 0.10)
    // Too old for a 10 second window.
    run("git", 30, 2.0)

    let snapshot = perf.snapshot()
    #expect(snapshot.rate(over: 10, at: now) == ["git": 0.2, "gh": 0.1])
    #expect(snapshot.longest(2, over: 10, at: now).map(\.duration) == [0.30, 0.10])
}

@Test func measuresWhatItWraps() throws {
    let perf = Perf()
    let timer = perf.begin("/usr/bin/git", ["status"])
    perf.end(timer)
    let run = try #require(perf.snapshot().recent.first)
    #expect(run.command == "git status")
    #expect(run.tool == "git")
    #expect(run.duration >= 0)
}

@Test func countsABusyRunLoopStepAsAHangButNotASleepOrTheLaunch() {
    var watch = HangWatch()
    // Launch work, before the window is there to answer anyone, isn't a hang.
    #expect(watch.note(at: 0, afterSleep: false) == nil)
    #expect(watch.note(at: 0.8, afterSleep: false) == nil)
    // Idle for the first time: from here on the window is waiting for you.
    #expect(watch.note(at: 2, afterSleep: true) == nil)
    #expect(watch.note(at: 2.1, afterSleep: false) == nil)
    // Busy from 2.1 to 2.5 without a break: a hang.
    #expect(watch.note(at: 2.5, afterSleep: false).map { ($0 * 10).rounded() / 10 } == 0.4)
    // Asleep until 5, waiting for something to do: not a hang.
    #expect(watch.note(at: 5, afterSleep: true) == nil)
    #expect(watch.note(at: 5.3, afterSleep: false).map { ($0 * 10).rounded() / 10 } == 0.3)
}

@Test func keepsTheLastBlockingRunsAndHangsApart() {
    let perf = Perf(capacity: 2)
    let now = Date()
    perf.record(Perf.Run(command: "git rev-parse", tool: "git", start: now, duration: 0.03, onMain: true))
    // The ring fills with other runs, and the blocking one stays known.
    for _ in 0..<5 { perf.record(Perf.Run(command: "git status", tool: "git", start: now, duration: 0.01, onMain: false)) }
    perf.recordHang(Perf.Hang(start: now, duration: 0.4))
    let snapshot = perf.snapshot()
    #expect(snapshot.blocking.map(\.command) == ["git rev-parse"])
    #expect(snapshot.onMain == 1)
    #expect(snapshot.hangs == [Perf.Hang(start: now, duration: 0.4)])
}

@Test func aLaunchBurstIsCalmAndALoopIsAProblem() {
    let now = Date()
    // 100 processes in the first seconds after launch, then quiet.
    let launch = Perf()
    for index in 0..<100 { launch.record(Perf.Run(command: "git status", tool: "git", start: now.addingTimeInterval(-Double(index) / 20), duration: 0.02, onMain: false)) }
    #expect(launch.snapshot().processLevel(at: now) == .good)

    // Opening the graph and the review panel, then working: about 2.5 a second over the minute.
    let working = Perf()
    for index in 0..<150 { working.record(Perf.Run(command: "git diff", tool: "git", start: now.addingTimeInterval(-Double(index) / 2.5), duration: 0.02, onMain: false)) }
    #expect(working.snapshot().processLevel(at: now) == .good)
    #expect(working.snapshot().started(over: 10, at: now) == ["git": 25])

    // 10 a second for a whole minute, as the hook loop #159 fixed was.
    let loop = Perf()
    for index in 0..<600 { loop.record(Perf.Run(command: "git status", tool: "git", start: now.addingTimeInterval(-Double(index) / 10), duration: 0.02, onMain: false)) }
    #expect(loop.snapshot().processLevel(at: now) == .problem)
}

@Test func judgesBlockingRunsHangsMemoryAndCPU() {
    let now = Date()
    let quick = Perf(), slow = Perf()
    quick.record(Perf.Run(command: "git rev-parse", tool: "git", start: now, duration: 0.03, onMain: true))
    slow.record(Perf.Run(command: "git rev-parse", tool: "git", start: now, duration: 0.12, onMain: true))
    #expect(Perf().snapshot().blockingLevel == .good)
    #expect(quick.snapshot().blockingLevel == .worthALook)
    #expect(slow.snapshot().blockingLevel == .problem)

    quick.recordHang(Perf.Hang(start: now, duration: 0.4))
    slow.recordHang(Perf.Hang(start: now, duration: 1.2))
    #expect(Perf().snapshot().hangLevel == .good)
    #expect(quick.snapshot().hangLevel == .worthALook)
    #expect(slow.snapshot().hangLevel == .problem)

    #expect(Perf.memoryLevel(300 << 20) == .good)
    #expect(Perf.memoryLevel(3 << 30) == .problem)
    #expect(Perf.cpuLevel(2) == .good)
    #expect(Perf.cpuLevel(90) == .problem)
}
