import Testing
@testable import FarolCore

/// The marked text of each changed line, easier to read in a test than offsets.
private func marked(base: [String], changed: [String]) -> [[String]] {
    zip(changed, InlineDiff.changes(base: base, changed: changed)).map { line, ranges in
        let units = Array(line.utf16)
        return ranges.map { String(decoding: units[$0], as: UTF16.self) }
    }
}

@Suite struct InlineDiffTests {
    @Test func tokensSplitWordsNumbersSpacesAndPunctuation() {
        let tokens = InlineDiff.tokens("  let x_1 = foo(3.5, \"é\")").map(String.init)
        #expect(tokens == ["  ", "let", " ", "x_1", " ", "=", " ", "foo", "(", "3.5", ",", " ", "\"", "é", "\"", ")"])
    }

    @Test func renamedIdentifier() {
        #expect(marked(base: ["let count = items.count"], changed: ["let total = items.count"]) == [["total"]])
    }

    @Test func addedArgument() {
        #expect(marked(base: ["send(change)"], changed: ["send(change, retries)"]) == [[", retries"]])
    }

    @Test func whitespaceOnlyChange() {
        #expect(marked(base: ["foo(a,b)"], changed: ["foo(a, b)"]) == [[" "]])
        #expect(marked(base: ["  return x"], changed: ["    return x"]) == [["    "]])
    }

    @Test func neighboringWordsMergeAcrossASpace() {
        #expect(marked(base: ["let total = old value + 1"], changed: ["let total = new thing + 1"]) == [["new thing"]])
    }

    @Test func differentLinesAreNotMarked() {
        #expect(marked(base: ["await api.send(change)"], changed: ["return this.pending.length"]) == [[]])
        #expect(marked(base: ["same line"], changed: ["same line"]) == [[]])
    }

    @Test func newLinesWithoutAncestorAreNotMarked() {
        #expect(marked(base: [], changed: ["added"]) == [[]])
    }

    @Test func pairsLinesWhenTheChunkGrew() {
        let base = ["func run() {", "    work(1)", "}"]
        let changed = ["func run() {", "    log(\"start\")", "    work(2)", "}"]
        #expect(marked(base: base, changed: changed) == [[], [], ["2"], []])
    }

    @Test func pairsLinesWhenTheChunkShrank() {
        let base = ["let a = 1", "let b = 2", "let c = 3"]
        #expect(marked(base: base, changed: ["let a = 1", "let c = 4"]) == [[], ["4"]])
    }

    @Test func longLinesAreSkipped() {
        let long = String(repeating: "a ", count: 300)
        #expect(marked(base: [long + "x"], changed: [long + "y"]) == [[]])
    }
}
