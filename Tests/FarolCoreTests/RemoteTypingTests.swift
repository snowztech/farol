import Testing
@testable import FarolCore

private let picture = "/Users/me/Library/Caches/Farol/Attachments/A.jpg"

@Test func returnWaitsLongerAfterALongerPaste() {
    #expect(RemoteTyping.returnDelay(afterPasteOf: "fix it", elapsed: 0) == 0.4)
    #expect(RemoteTyping.returnDelay(afterPasteOf: "a\nb\nc", elapsed: 0) > RemoteTyping.returnDelay(afterPasteOf: "a", elapsed: 0))
    // A paste of a whole log waits no longer than one of a few screens.
    let log = Array(repeating: "line", count: 500).joined(separator: "\n")
    #expect(RemoteTyping.returnDelay(afterPasteOf: log, elapsed: 0) == RemoteTyping.returnDelay(afterPasteOf: log.split(separator: "\n").prefix(8).joined(separator: "\n"), elapsed: 0))
}

@Test func aPictureGivesTheAgentTimeToOpenIt() {
    let reply = [picture, picture, "what is off here?"].joined(separator: "\n")
    #expect(RemoteTyping.returnDelay(afterPasteOf: reply, elapsed: 0) > 1.5)
}

@Test func returnGoesAtOnceWhenThePasteWasLongAgo() {
    #expect(RemoteTyping.returnDelay(afterPasteOf: "a\nb\nc", elapsed: 0.3) > 0)
    #expect(RemoteTyping.returnDelay(afterPasteOf: "a\nb\nc", elapsed: 5) == 0)
}
