import Foundation
import Testing
@testable import FarolCore

private func write(_ text: String, to path: String, in repo: String) throws {
    let url = URL(fileURLWithPath: repo).appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func lines(_ matches: [FileSearch.Match]) -> [String] { matches.map { "\($0.path):\($0.line)" } }

@Test func findsTheNameUnderTheClick() {
    let code = "let total = computeTotal(order)"
    #expect(Definitions.word(in: code, at: 14) == "computeTotal")
    #expect(Definitions.word(in: code, at: 5) == "total")
    // At the end of a name, as a click just after its last letter lands.
    #expect(Definitions.word(in: code, at: 9) == "total")
    #expect(Definitions.word(in: "  + 12", at: 4) == nil)
    #expect(Definitions.word(in: "", at: 0) == nil)
    #expect(Definitions.word(in: "<my-button x>", at: 4, hyphens: true) == "my-button")
    #expect(Definitions.word(in: "<my-button x>", at: 4) == "button")
    // The whole name is what gets colored, whichever letter the mouse is on.
    #expect(Definitions.wordRange(in: code, at: 14) == NSRange(location: 12, length: 12))
    #expect(Definitions.wordRange(in: code, at: 12) == NSRange(location: 12, length: 12))
    #expect(Definitions.wordRange(in: "a -b", at: 2, hyphens: true) == NSRange(location: 3, length: 1))
}

@Test func findsSwiftDeclarations() throws {
    let box = try Sandbox()
    try write("""
    struct Order {
        enum Status { case pending, shipped }
        private let items: [String]
        mutating func apply(discount: Double) {}
    }
    func computeTotal(_ order: Order) {}
    """, to: "Sources/Store.swift", in: box.repo)
    try write("computeTotal(order)\n", to: "Sources/main.swift", in: box.repo)
    let from = box.repo + "/Sources/main.swift"

    #expect(lines(Definitions.find("computeTotal", from: from, in: box.repo)) == ["Sources/Store.swift:6"])
    #expect(lines(Definitions.find("Order", from: from, in: box.repo)) == ["Sources/Store.swift:1"])
    #expect(lines(Definitions.find("apply", from: from, in: box.repo)) == ["Sources/Store.swift:4"])
    #expect(lines(Definitions.find("items", from: from, in: box.repo)) == ["Sources/Store.swift:3"])
    #expect(lines(Definitions.find("shipped", from: from, in: box.repo)) == ["Sources/Store.swift:2"])
    #expect(Definitions.find("missing", from: from, in: box.repo).isEmpty)
}

@Test func findsGoDeclarationsIncludingMethodsAndConstants() throws {
    let box = try Sandbox()
    try write("""
    package server

    type Order struct{}

    const (
    \tStatusPending Status = iota
    \tStatusShipped
    )

    func ComputeTotal(o Order) float64 { return 0 }

    func (o *Order) Apply(discount float64) {}
    """, to: "server/orders.go", in: box.repo)
    try write("package server\n", to: "server/main.go", in: box.repo)
    let from = box.repo + "/server/main.go"

    #expect(lines(Definitions.find("ComputeTotal", from: from, in: box.repo)) == ["server/orders.go:10"])
    #expect(lines(Definitions.find("Apply", from: from, in: box.repo)) == ["server/orders.go:12"])
    #expect(lines(Definitions.find("Order", from: from, in: box.repo)) == ["server/orders.go:3"])
    #expect(lines(Definitions.find("StatusPending", from: from, in: box.repo)) == ["server/orders.go:6"])
    #expect(lines(Definitions.find("StatusShipped", from: from, in: box.repo)) == ["server/orders.go:7"])
}

@Test func findsVueScriptsComponentsAndTheScriptsTheyImport() throws {
    let box = try Sandbox()
    try write("<template><button /></template>\n", to: "web/components/MyButton.vue", in: box.repo)
    try write("export function useCart() {}\nexport const formatPrice = (v: number) => v\n", to: "web/useCart.ts", in: box.repo)
    try write("""
    <template><my-button /></template>
    <script>
    export default {
      methods: {
        save() {},
        reset: function () {},
      },
    }
    </script>
    """, to: "web/Cart.vue", in: box.repo)
    let from = box.repo + "/web/Cart.vue"

    #expect(lines(Definitions.find("my-button", from: from, in: box.repo)) == ["web/components/MyButton.vue:1"])
    #expect(lines(Definitions.find("MyButton", from: from, in: box.repo)) == ["web/components/MyButton.vue:1"])
    #expect(lines(Definitions.find("useCart", from: from, in: box.repo)) == ["web/useCart.ts:1"])
    #expect(lines(Definitions.find("formatPrice", from: from, in: box.repo)) == ["web/useCart.ts:2"])
    #expect(lines(Definitions.find("save", from: from, in: box.repo)) == ["web/Cart.vue:5"])
    #expect(lines(Definitions.find("reset", from: from, in: box.repo)) == ["web/Cart.vue:6"])
}

@Test func theNearestAnswerComesFirst() throws {
    let box = try Sandbox()
    try write("func run() {}\n", to: "Sources/App/Other.swift", in: box.repo)
    try write("func run() {}\nrun()\n", to: "Sources/App/main.swift", in: box.repo)
    try write("func run() {}\n", to: "Sources/Lib/Lib.swift", in: box.repo)
    let found = Definitions.find("run", from: box.repo + "/Sources/App/main.swift", in: box.repo)
    // The clicked file, then its folder, then the rest.
    #expect(lines(found) == ["Sources/App/main.swift:1", "Sources/App/Other.swift:1", "Sources/Lib/Lib.swift:1"])
}

@Test func aFileWithoutALanguageHasNoDefinitions() throws {
    let box = try Sandbox()
    try write("func run() {}\n", to: "notes.txt", in: box.repo)
    #expect(Definitions.find("run", from: box.repo + "/notes.txt", in: box.repo).isEmpty)
}

@Test func findsLocalsAndGoFields() throws {
    let box = try Sandbox()
    try write("""
    func load(paths: [String]) {
        guard let first = paths.first, let last = paths.last else { return }
        for (index, path) in paths.enumerated() {}
    }
    """, to: "Sources/Load.swift", in: box.repo)
    try write("""
    package server

    type Order struct {
    \tID    string `json:"id"`
    \tItems []Item // what was bought
    }

    func handle() {
    \tfor i, item := range items {}
    \tresult, err := run()
    \tID(result)
    }
    """, to: "server/order.go", in: box.repo)
    let swift = box.repo + "/Sources/Load.swift"
    let go = box.repo + "/server/order.go"

    #expect(lines(Definitions.find("first", from: swift, in: box.repo)) == ["Sources/Load.swift:2"])
    #expect(lines(Definitions.find("last", from: swift, in: box.repo)) == ["Sources/Load.swift:2"])
    #expect(lines(Definitions.find("path", from: swift, in: box.repo)) == ["Sources/Load.swift:3"])
    #expect(lines(Definitions.find("ID", from: go, in: box.repo)) == ["server/order.go:4"])
    #expect(lines(Definitions.find("Items", from: go, in: box.repo)) == ["server/order.go:5"])
    #expect(lines(Definitions.find("item", from: go, in: box.repo)) == ["server/order.go:9"])
    #expect(lines(Definitions.find("err", from: go, in: box.repo)) == ["server/order.go:10"])
}

@Test func opensWithoutAskingWhenTheClickedFileSettlesIt() {
    let match = { (path: String, line: Int) in FileSearch.Match(path: path, line: line, text: "") }
    let here = "/repo/a.swift"
    // One answer, or one in the clicked file, opens straight away.
    #expect(Definitions.best([match("b.swift", 3)], from: here, in: "/repo", line: 1) == match("b.swift", 3))
    #expect(Definitions.best([match("a.swift", 9), match("b.swift", 3)], from: here, in: "/repo", line: 1) == match("a.swift", 9))
    // Several in the clicked file: the nearest above the click, as a local in scope.
    let locals = [match("a.swift", 2), match("a.swift", 10), match("a.swift", 20)]
    #expect(Definitions.best(locals, from: here, in: "/repo", line: 15) == match("a.swift", 10))
    #expect(Definitions.best(locals, from: here, in: "/repo", line: 1) == nil)
    // Only elsewhere, in several files: the menu asks.
    #expect(Definitions.best([match("b.swift", 3), match("c.swift", 4)], from: here, in: "/repo", line: 1) == nil)
}

@Test func aLocalInAnotherFileIsNoAnswer() throws {
    let box = try Sandbox()
    try write("final class Pipe {\n    let handle: Int\n}\n", to: "Sources/Pipe.swift", in: box.repo)
    try write("func read() {\n        let handle = 1\n        guard let handle = open() else { return }\n}\n", to: "Sources/Read.swift", in: box.repo)
    try write("pipe.handle\n", to: "Sources/main.swift", in: box.repo)
    #expect(lines(Definitions.find("handle", from: box.repo + "/Sources/main.swift", in: box.repo)) == ["Sources/Pipe.swift:2"])
}

@Test func indexesEveryCaseOnALineAndNoKeywords() throws {
    let box = try Sandbox()
    try write("enum Mode {\n    case light, dark(Int), auto = 3\n}\nswitch mode {\ncase .light: break\n}\n", to: "Mode.swift", in: box.repo)
    try write("package a\n\nfunc f() error {\n\treturn err\n}\n", to: "a.go", in: box.repo)
    let swift = Definitions.Index.build(for: box.repo + "/Mode.swift", in: box.repo)
    for name in ["light", "dark", "auto"] {
        #expect(lines(swift.find(name, from: box.repo + "/x.swift", text: "")) == ["Mode.swift:2"])
    }
    let go = Definitions.Index.build(for: box.repo + "/a.go", in: box.repo)
    #expect(go.find("return", from: box.repo + "/a.go", text: "").isEmpty)
    #expect(lines(go.find("f", from: box.repo + "/b.go", text: "")) == ["a.go:3"])
}

@Test func readsLocalsFromTheTextInThePaneNotTheDisk() throws {
    let box = try Sandbox()
    try write("func run() {}\n", to: "main.swift", in: box.repo)
    let index = Definitions.Index.build(for: box.repo + "/main.swift", in: box.repo)
    // An unsaved edit adds a local the file on disk doesn't have yet.
    let edited = "func run() {\n    let total = 1\n    print(total)\n}\n"
    #expect(lines(index.find("total", from: box.repo + "/main.swift", text: edited)) == ["main.swift:2"])
}

@Test func aCallThroughAnotherValueAsksAndFindsTheInterface() throws {
    let box = try Sandbox()
    let engine = """
    package ai

    type Provider interface {
    \tGenerateQuery(req QueryRequest) (*QueryResponse, error)
    }

    func (e *Engine) GenerateQuery(req QueryRequest) (*QueryResponse, error) {
    \treturn e.provider.GenerateQuery(req)
    }
    """
    try write(engine, to: "ai/engine.go", in: box.repo)
    try write("package ai\n\nfunc (o *OpenAI) GenerateQuery(req QueryRequest) (*QueryResponse, error) {\n\treturn nil, nil\n}\n",
              to: "ai/openai.go", in: box.repo)
    let file = box.repo + "/ai/engine.go"
    let found = Definitions.find("GenerateQuery", from: file, in: box.repo)
    #expect(lines(found) == ["ai/engine.go:4", "ai/engine.go:7", "ai/openai.go:3"])
    // e.provider.GenerateQuery is the provider's, so the method beside it is no hint and the list asks.
    let call = (engine as NSString).range(of: "GenerateQuery(req)")
    let range = NSRange(location: call.location, length: "GenerateQuery".count)
    #expect(Definitions.isMember(in: engine, at: range))
    #expect(Definitions.best(found, from: file, in: box.repo, line: 8, member: true) == nil)
    #expect(!Definitions.isMember(in: "self.run()", at: NSRange(location: 5, length: 3)))
    #expect(!Definitions.isMember(in: "run()", at: NSRange(location: 0, length: 3)))
}
