import Foundation
import Testing
@testable import FarolCore

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
}()

/// November 2026: the 6th is a Friday.
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func schedule(_ days: Schedule.Days = .everyDay, since: Date) -> Schedule {
    Schedule(name: "Article", task: "write an article", repo: "/r", branch: "write-article", agent: "claude",
             days: days, hour: 9, minute: 0, since: since)
}

@Test func owesTodaysRunOnceItsTimeComes() {
    let made = schedule(since: at(5, 18))
    #expect(made.owed(at: at(6, 8, 59), calendar: calendar) == nil)
    #expect(made.owed(at: at(6, 9), calendar: calendar) == at(6, 9))
    #expect(made.owed(at: at(6, 14), calendar: calendar) == at(6, 9))
}

@Test func owesNothingOnceTheRunStarted() {
    #expect(schedule(since: at(6, 9, 1)).owed(at: at(6, 23), calendar: calendar) == nil)
}

/// Farol was closed or the Mac asleep for days: one run, not one a day missed.
@Test func missedDaysOweOneRun() {
    #expect(schedule(since: at(2, 9, 1)).owed(at: at(6, 10), calendar: calendar) == at(6, 9))
    #expect(schedule(since: at(2, 9, 1)).owed(at: at(6, 8), calendar: calendar) == at(5, 9))
}

@Test func weekdaysSkipTheWeekend() {
    let weekdays = schedule(.weekdays, since: at(6, 9, 1))
    #expect(weekdays.owed(at: at(8, 12), calendar: calendar) == nil)
    #expect(weekdays.owed(at: at(9, 9), calendar: calendar) == at(9, 9))
    #expect(weekdays.next(after: at(6, 10), calendar: calendar) == at(9, 9))
    #expect(schedule(since: at(6, 9, 1)).next(after: at(6, 10), calendar: calendar) == at(7, 9))
}

@Test func eachRunGetsTheDayInItsBranch() {
    #expect(schedule(since: at(6, 9)).branch(on: at(6, 9), calendar: calendar) == "write-article-2026-11-06")
}

@Test func aOneTimeTaskIsOwedOnceAtItsTime() {
    var later = schedule(since: at(6, 18))
    later.once = at(7, 9)
    #expect(later.owed(at: at(7, 8), calendar: calendar) == nil)
    #expect(later.owed(at: at(8, 12), calendar: calendar) == at(7, 9))
    #expect(later.branch(on: at(7, 9), calendar: calendar) == "write-article")
}

@Test func saysWhenItRunsNextInFewWords() {
    let daily = schedule(since: at(6, 9, 1))
    #expect(!daily.upcoming(at: at(6, 8), calendar: calendar).hasPrefix("tmrw"))
    #expect(daily.upcoming(at: at(6, 10), calendar: calendar).hasPrefix("tmrw "))
    #expect(schedule(.weekdays, since: at(6, 9, 1)).upcoming(at: at(6, 10), calendar: calendar).hasPrefix("Mon"))
}
