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
