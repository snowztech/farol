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

@Test func readsFrontMatterAsYAML() {
    let blocks = Markdown.blocks(in: "---\nname: farol\ndescription: Farol\n---\n\n# Farol")
    #expect(blocks == [.code(language: "yaml", text: "name: farol\ndescription: Farol"), .heading(level: 1, text: "Farol")])
    // A rule that opens the file without closing is still a rule.
    #expect(Markdown.blocks(in: "---\nafter") == [.rule, .paragraph("after")])
}

@Test func readsLinksDefinedElsewhere() {
    let text = """
    See [0.2.1], [the docs][docs], [Docs][] and [no such link].

    ```
    [kept]: https://code
    ```

    [0.2.1]: https://farol.sh/releases/0.2.1
    [docs]: <https://farol.sh/docs> "Docs"
    """
    #expect(Markdown.blocks(in: text) == [
        .paragraph("See [0.2.1](https://farol.sh/releases/0.2.1), [the docs](https://farol.sh/docs), [Docs](https://farol.sh/docs) and [no such link]."),
        .code(language: nil, text: "[kept]: https://code"),
    ])
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

@Test func readsTheHTMLThatReadmesUse() {
    let readme = """
    <div align="center">
      <img src="logo.png" alt="logo" width="400" />
      <h3><em>Switch accounts</em></h3>
      <p>
        <a href="https://x.dev"><img src="https://badge.svg" alt="Build" /></a>
      </p>
    </div>
    <!-- hidden
    note -->

    Line<br>
    <hr>
    """
    #expect(Markdown.blocks(in: readme) == [
        .paragraph(#"<img src="logo.png" alt="logo" width="400" />"#),
        .heading(level: 3, text: "<em>Switch accounts</em>"),
        .paragraph(#"<a href="https://x.dev"><img src="https://badge.svg" alt="Build" /></a>"#),
        .paragraph("Line<br>"),
        .rule,
    ])
}

@Test func turnsInlineHTMLIntoMarkdown() {
    #expect(Markdown.inlineHTML(#"<img src="logo.png" alt="logo" width="400" />"#) == "![logo](logo.png#width=400)")
    #expect(Markdown.inlineHTML(#"<a href="https://x.dev"><img src="b.svg" alt="Build" /></a>"#) == "[![Build](b.svg)](https://x.dev)")
    #expect(Markdown.inlineHTML("the <b> go-gituser </b> root <br>\nnext") == "the **go-gituser** root\u{2028}next")
    // Code spans and words in brackets keep their text.
    #expect(Markdown.inlineHTML("run `<b>x</b>` for <mode>") == "run `<b>x</b>` for <mode>")
}

@Test func keepsLookalikesAsText() {
    #expect(Markdown.blocks(in: "The year\n2024. was good") == [.paragraph("The year 2024. was good")])
    // A header with more cells than the delimiter row isn't a table.
    #expect(Markdown.blocks(in: "a | b | c\n--- | ---") == [.paragraph("a | b | c --- | ---")])
}
