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
    #expect(tokens(code, "main.go") == ["func:keyword", "// start:comment", "\"hi\":string", "42:number"])
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
    #expect(Syntax.language(for: "README.md") == nil)
    #expect(Syntax.language(for: "Makefile") != nil)
}

@Test func htmlColorsTagsAttributesAndComments() {
    let code = "<!-- hi --><p class=\"a\">Farol's</p>"
    #expect(tokens(code, "index.html") == ["<!-- hi -->:comment", "p:keyword", "\"a\":string", "p:keyword"])
}
