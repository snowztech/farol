import Testing
@testable import FarolCore

@Test func returnWaitsLongerAfterALongerPaste() {
    #expect(RemoteTyping.returnDelay(afterPasteOf: 1, elapsed: 0) == 0.4)
    #expect(RemoteTyping.returnDelay(afterPasteOf: 3, elapsed: 0) > RemoteTyping.returnDelay(afterPasteOf: 1, elapsed: 0))
    // A paste of a whole log waits no longer than one of a few screens.
    #expect(RemoteTyping.returnDelay(afterPasteOf: 500, elapsed: 0) == RemoteTyping.returnDelay(afterPasteOf: 8, elapsed: 0))
}

@Test func returnGoesAtOnceWhenThePasteWasLongAgo() {
    #expect(RemoteTyping.returnDelay(afterPasteOf: 3, elapsed: 0.3) > 0)
    #expect(RemoteTyping.returnDelay(afterPasteOf: 3, elapsed: 5) == 0)
}
