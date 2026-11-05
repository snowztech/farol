import Testing
@testable import FarolCore

private func place(_ path: String, _ line: Int) -> NavigationHistory.Place { .init(path: path, line: line) }

@Test func goesBackToWhereYouLeftAndForwardAgain() {
    var history = NavigationHistory()
    // From a.swift line 10 to b.swift, then from b.swift line 3 to c.swift.
    history.record(leaving: place("a.swift", 10))
    history.record(leaving: place("b.swift", 3))

    #expect(history.goBack(from: place("c.swift", 1)) == place("b.swift", 3))
    #expect(history.goBack(from: place("b.swift", 3)) == place("a.swift", 10))
    #expect(history.goBack(from: place("a.swift", 10)) == nil)

    #expect(history.goForward(from: place("a.swift", 10)) == place("b.swift", 3))
    #expect(history.goForward(from: place("b.swift", 3)) == place("c.swift", 1))
    #expect(history.goForward(from: place("c.swift", 1)) == nil)
}

@Test func aNewJumpAfterGoingBackDropsWhatWasUndone() {
    var history = NavigationHistory()
    history.record(leaving: place("a.swift", 1))
    _ = history.goBack(from: place("b.swift", 1))
    #expect(history.canGoForward)

    history.record(leaving: place("a.swift", 1))
    #expect(!history.canGoForward)
}

@Test func leavingTheSamePlaceTwiceIsKeptOnce() {
    var history = NavigationHistory()
    history.record(leaving: place("a.swift", 5))
    history.record(leaving: place("a.swift", 5))
    #expect(history.goBack(from: place("b.swift", 1)) == place("a.swift", 5))
    #expect(!history.canGoBack)
}

@Test func skipsPlacesThatNoLongerExist() {
    var history = NavigationHistory()
    history.record(leaving: place("kept.swift", 2))
    history.record(leaving: place("deleted.swift", 9))
    let back = history.goBack(from: place("now.swift", 1), where: { $0.path != "deleted.swift" })
    #expect(back == place("kept.swift", 2))
    // The one skipped isn't a way forward either: only where you were is.
    #expect(history.goForward(from: place("kept.swift", 2)) == place("now.swift", 1))
}

@Test func keepsOnlyTheLatestHundredPlaces() {
    var history = NavigationHistory()
    for line in 1...150 { history.record(leaving: place("a.swift", line)) }
    var oldest: NavigationHistory.Place?
    var current = place("z.swift", 0)
    while let previous = history.goBack(from: current) {
        oldest = previous
        current = previous
    }
    #expect(oldest == place("a.swift", 51))
}
