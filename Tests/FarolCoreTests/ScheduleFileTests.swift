import Foundation
import Testing
@testable import FarolCore

private let home = "/Users/me"

@Test func readsATaskFile() throws {
    let text = """
    ---
    name: Write the article
    when: mon, thu 9:30
    repos: ~/dev/blog, /srv/site
    branch: write-article
    agent: claude
    ---
    Write today's article.

    Keep it short.
    """
    let task = try ScheduleFile.parse(text, id: "write-article", home: home)
    #expect(task.id == "write-article")
    #expect(task.name == "Write the article")
    #expect(task.weekdays == [2, 5])
    #expect(task.hour == 9 && task.minute == 30)
    #expect(task.repos == ["/Users/me/dev/blog", "/srv/site"])
    #expect(task.task == "Write today's article.\n\nKeep it short.")
}

@Test func readsEachWayOfSayingWhen() {
    #expect(ScheduleFile.when("every day 9:00")?.weekdays == Schedule.everyDay)
    #expect(ScheduleFile.when("daily 21h30")?.minutes == 1290)
    #expect(ScheduleFile.when("weekdays 9:00 am")?.weekdays == Schedule.workweek)
    #expect(ScheduleFile.when("Monday, Friday 18:00")?.weekdays == [2, 6])
    #expect(ScheduleFile.when("once 2026-11-12 14:30")?.once != nil)
    #expect(ScheduleFile.when("someday 9:00") == nil)
    #expect(ScheduleFile.when("every day") == nil)
}

/// Farol writes the same file it reads, so saving from the app never loses what you wrote.
@Test func writesWhatItReads() throws {
    for when in ["every day 9:00", "weekdays 7:05", "tue, sat 18:00", "once 2026-11-12 14:30"] {
        let text = "---\nname: Bump\nwhen: \(when)\nrepos: ~/dev/app\nbranch: bump\nagent: codex\n---\nBump the deps.\n"
        let task = try ScheduleFile.parse(text, id: "bump", home: home)
        #expect(ScheduleFile.text(for: task, home: home) == text)
    }
}

@Test func saysWhyAFileDoesNotRead() {
    #expect(throws: ScheduleFile.Problem.noFrontMatter) { try ScheduleFile.parse("Just a prompt", id: "x") }
    #expect(throws: ScheduleFile.Problem.missing("when")) { try ScheduleFile.parse("---\nrepos: /r\n---\nGo", id: "x") }
    #expect(throws: ScheduleFile.Problem.unreadable("when", "fortnightly 9:00")) {
        try ScheduleFile.parse("---\nwhen: fortnightly 9:00\nrepos: /r\n---\nGo", id: "x")
    }
}

@Test func namesANewFileAfterItsBranch() {
    let task = Schedule(name: "", task: "", repos: [], branch: "feat/article", agent: "", weekdays: [], hour: 9, minute: 0, since: .now)
    #expect(ScheduleFile.name(for: task) { $0 == "feat-article" } == "feat-article-2")
}

/// A second config folder is saved as its path, written short and read back in full.
@Test func keepsAnAgentFolderShort() throws {
    let text = "---\nname: Bump\nwhen: every day 9:00\nrepos: ~/dev/app\nbranch: bump\nagent: ~/.claude-work\n---\nBump the deps.\n"
    let task = try ScheduleFile.parse(text, id: "bump", home: home)
    #expect(task.agent == "/Users/me/.claude-work")
    #expect(ScheduleFile.text(for: task, home: home) == text)
}
