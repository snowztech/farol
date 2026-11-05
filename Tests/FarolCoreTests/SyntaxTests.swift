import Foundation
import Testing
@testable import FarolCore

/// Each token as the text it covers and its kind, which reads better in a failure than ranges do.
private func tokens(_ text: String, _ path: String) -> [String] {
    Syntax.tokens(in: text, Syntax.language(for: path)!).map { token in
        "\((text as NSString).substring(with: token.range)):\(token.kind)"
    }
}

@Test func colorsGoKeywordsStringsNumbersAndComments() {
    let code = "func main() { // start\n\tx := \"hi\" + 42\n}"
    #expect(tokens(code, "main.go") == ["func:keyword", "main:function", "// start:comment", "\"hi\":string", "42:number"])
}

@Test func blockCommentsAndEscapedQuotes() {
    let code = "/* a \"b\" */ let s = \"say \\\"hi\\\"\""
    #expect(tokens(code, "a.swift") == ["/* a \"b\" */:comment", "let:keyword", "\"say \\\"hi\\\"\":string"])
}

@Test func anUnclosedQuoteStopsAtTheLineEnd() {
    let code = "x = \"open\ny = 1"
    #expect(tokens(code, "a.py") == ["\"open:string", "1:number"])
}

@Test func namesAfterADotAreNotKeywords() {
    #expect(tokens("case .default: obj.type", "a.swift") == ["case:keyword"])
}

@Test func unknownFilesAreNotColored() {
    #expect(Syntax.language(for: "notes.txt") == nil)
    #expect(Syntax.language(for: "Makefile") != nil)
}

@Test func codeFencesNameTheirLanguage() {
    for name in ["swift", "ts", "TypeScript", "bash", "json", "yaml", "dockerfile", "c++"] {
        #expect(Syntax.language(named: name) != nil, "\(name)")
    }
    #expect(Syntax.language(named: "text") == nil)
    #expect(Syntax.language(named: "") == nil)
}

@Test func htmlColorsTagsAttributesAndComments() {
    let code = "<!-- hi --><p class=\"a\">Farol's</p>"
    #expect(tokens(code, "index.html") == ["<!-- hi -->:comment", "p:keyword", "\"a\":string", "p:keyword"])
}

@Test func markdownColorsHeadingsListsCodeAndLinks() {
    let text = "# Title\n- see `make lint` and [docs](https://x.dev)\n```\nlet a = 1\n```"
    #expect(tokens(text, "README.md") == [
        "# Title:keyword", "-:keyword", "`make lint`:string", "(https://x.dev):comment",
        "```:string", "let a = 1:string", "```:string",
    ])
}

@Test func colorsTypesByTheirCapitalAndFunctionsByTheirCall() {
    let go = "func (e *Engine) Run(req QueryRequest) {\n\tvar b strings.Builder\n\treturn NewOpenAI(prompt.System, MAX_TOKENS)\n}"
    #expect(tokens(go, "a.go") == [
        "func:keyword", "Engine:type", "Run:function", "QueryRequest:type",
        "var:keyword", "return:keyword", "NewOpenAI:function",
    ])
    // In Swift a capitalized call makes a value of that type, and a method call is still a function.
    let swift = "let token = Token(range: r)\nview.layout()"
    #expect(tokens(swift, "a.swift") == ["let:keyword", "Token:type", "layout:function"])
    // Neither convention holds in a shell script or JSON, so their names stay plain.
    #expect(tokens("Run() {\n  echo Hi\n}", "a.sh") == [])
    #expect(tokens("{\"Name\": true}", "a.json") == ["\"Name\":string", "true:keyword"])
}
