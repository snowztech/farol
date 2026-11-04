import Testing
@testable import FarolCore

@Test func splitsTheTitleFromTheDescription() {
    let text = RequestMessage.parse("Title: Show a loader\n\n## What and why\n\nIt was silent.\n")
    #expect(text == RequestMessage.Text(title: "Show a loader", body: "## What and why\n\nIt was silent."))
}

@Test func aReplyOfOneLineIsAnEmptyDescription() {
    #expect(RequestMessage.parse("Show a loader") == RequestMessage.Text(title: "Show a loader", body: ""))
    #expect(RequestMessage.parse("  \n") == nil)
}

@Test func dropsTheHeadingMarkAndTheCodeBlockAroundAReply() {
    let text = RequestMessage.parse("```\n# Show a loader\n\nIt was silent.\n```")
    #expect(text == RequestMessage.Text(title: "Show a loader", body: "It was silent."))
}
