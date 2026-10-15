import Testing
@testable import FarolCore

@Test func readsHeadingsParagraphsAndRules() {
    let blocks = Markdown.blocks(in: "# Plan ##\n\nOne\ntwo  \nthree\n\nSetext\n---\n\n***")
    #expect(blocks == [
        .heading(level: 1, text: "Plan"),
        // A soft break joins lines, two trailing spaces keep the break.
        .paragraph("One two\nthree"),
        .heading(level: 2, text: "Setext"),
        .rule,
    ])
    #expect(Markdown.blocks(in: "#hashtag") == [.paragraph("#hashtag")])
}

@Test func readsFencedCodeAsItIs() {
    let blocks = Markdown.blocks(in: "```swift\nlet x = 1\n\n  # not a heading\n```\nafter")
    #expect(blocks == [.code(language: "swift", text: "let x = 1\n\n  # not a heading"), .paragraph("after")])
    // An unclosed fence runs to the end.
    #expect(Markdown.blocks(in: "~~~\ncode") == [.code(language: nil, text: "code")])
}

@Test func readsNestedListsAndTasks() {
    let blocks = Markdown.blocks(in: "- [ ] todo\n- [x] done\n  more\n  - inner\n\n    second paragraph\n1. one\n")
    let inner = Markdown.Block.list(ordered: false, start: 1, items: [
        .init(checked: nil, blocks: [.paragraph("inner"), .paragraph("second paragraph")]),
    ])
    #expect(blocks == [
        .list(ordered: false, start: 1, items: [
            .init(checked: false, blocks: [.paragraph("todo")]),
            .init(checked: true, blocks: [.paragraph("done more"), inner]),
        ]),
        .list(ordered: true, start: 1, items: [.init(checked: nil, blocks: [.paragraph("one")])]),
    ])
    #expect(Markdown.blocks(in: "3. three\n4. four") == [.list(ordered: true, start: 3, items: [
        .init(checked: nil, blocks: [.paragraph("three")]), .init(checked: nil, blocks: [.paragraph("four")]),
    ])])
    // Without a space after the dash, it's text.
    #expect(Markdown.blocks(in: "-x") == [.paragraph("-x")])
}

@Test func readsQuotesWithLazyLines() {
    #expect(Markdown.blocks(in: "> quoted\nlazy\n> - item\n\nafter") == [
        .quote([.paragraph("quoted lazy"), .list(ordered: false, start: 1, items: [.init(checked: nil, blocks: [.paragraph("item")])])]),
        .paragraph("after"),
    ])
}

@Test func readsTables() {
    let blocks = Markdown.blocks(in: "| Name | Value |\n|:--|--:|\n| a \\| b | `1` |\n| c |\n\nafter")
    #expect(blocks == [.table(header: ["Name", "Value"], rows: [["a | b", "`1`"], ["c", ""]]), .paragraph("after")])
    // A pipe in a paragraph without a delimiter row under it is just text.
    #expect(Markdown.blocks(in: "a | b\nc") == [.paragraph("a | b c")])
}

@Test func offersThePreviewForMarkdownFiles() {
    #expect(Markdown.handles("/repo/README.md"))
    #expect(Markdown.handles("notes.MARKDOWN"))
    #expect(!Markdown.handles("main.swift"))
}
