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

@Test func startsFromTheFirstCommitAndListsTheOthers() throws {
    let box = try Sandbox()
    try Git.run(["config", "user.name", "Farol"], in: box.repo)
    try Git.run(["config", "user.email", "farol@example.com"], in: box.repo)
    try History.createBranch("feat", from: "main", in: box.repo)
    try Git.run(["commit", "--allow-empty", "-m", "feat: add the menu", "-m", "It opens a sheet."], in: box.repo)
    #expect(RequestMessage.fromCommits(head: "feat", base: "main", in: box.repo)
        == RequestMessage.Text(title: "feat: add the menu", body: "It opens a sheet."))

    try Git.run(["commit", "--allow-empty", "-m", "fix: size the picker"], in: box.repo)
    #expect(RequestMessage.fromCommits(head: "feat", base: "main", in: box.repo)
        == RequestMessage.Text(title: "feat: add the menu", body: "It opens a sheet.\n\n- fix: size the picker"))

    // Nothing on top of the base, or a base nobody knows, leaves the sheet empty.
    #expect(RequestMessage.fromCommits(head: "main", base: "main", in: box.repo) == nil)
    #expect(RequestMessage.fromCommits(head: "feat", base: "nowhere", in: box.repo) == nil)
}
