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
    #expect(tokens("case .default: obj.type", "a.swift") == ["case:keyword", "default:property", "type:property"])
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
    #expect(tokens(code, "index.html") == ["<!-- hi -->:comment", "p:tag", "\"a\":string", "p:tag"])
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
        "var:keyword", "Builder:property", "return:keyword", "NewOpenAI:function", "System:property",
    ])
    // In Swift a capitalized call makes a value of that type, and a method call is still a function.
    let swift = "let token = Token(range: r)\nview.layout()"
    #expect(tokens(swift, "a.swift") == ["let:keyword", "Token:type", "layout:function"])
    // Lower-case built-in types, and a Go conversion to one.
    #expect(tokens("func f(name string) error { return errors.New(string(b)) }", "a.go") == [
        "func:keyword", "f:function", "string:type", "error:type", "return:keyword", "New:function", "string:type",
    ])
    #expect(tokens("const total: number = count(ids as string[])", "a.ts") == [
        "const:keyword", "number:type", "count:function", "as:keyword", "string:type",
    ])
    // Neither convention holds in a shell script or JSON, so their names stay plain.
    #expect(tokens("Run() {\n  echo Hi\n}", "a.sh") == [])
    #expect(tokens("{\"Name\": true}", "a.json") == ["\"Name\":string", "true:keyword"])
}

@Test func colorsKeysAndMembersAsPropertiesButNotTypedVariables() {
    let go = "return &Engine{\n\tprovider: NewOpenAI(apiKey),\n}, req.DatabaseType, &http.Client{Timeout: 30}"
    #expect(tokens(go, "a.go") == [
        "return:keyword", "Engine:type", "provider:property", "NewOpenAI:function", "DatabaseType:property",
        "Client:property", "Timeout:property", "30:number",
    ])
    let ts = "interface User {\n  id: string\n}\nconst where = { id: userId }\nfunction find(id: string) {}"
    #expect(tokens(ts, "a.ts") == [
        "interface:keyword", "User:type", "id:property", "string:type",
        "const:keyword", "id:property", "function:keyword", "find:function", "string:type",
    ])
    // A type after the colon, a path and Go's := aren't keys.
    #expect(tokens("let map: [String: Int]", "a.swift") == ["let:keyword", "String:type", "Int:type"])
    #expect(tokens("x := 1", "a.go") == ["1:number"])
}

@Test func vueColorsTheScriptAsTypeScript() {
    let code = "<script setup lang=\"ts\">\nimport { ref } from 'vue'\nconst count = ref<number>(0)\nfunction save(): void {}\ninterface User { name: string }\n</script>"
    #expect(tokens(code, "A.vue") == [
        "script:tag",
        "\"ts\":string",
        "import:keyword",
        "from:keyword",
        "'vue':string",
        "const:keyword",
        "number:type",
        "0:number",
        "function:keyword",
        "save:function",
        "void:keyword",
        "interface:keyword",
        "User:type",
        "name:property",
        "string:type",
        "script:tag",
    ])
}

@Test func vueColorsDirectivesAndTheExpressionsInThem() {
    let code = "<template>\n  <my-button v-if=\"count > 0 && ok\" :class=\"{ active: isOn }\" @click=\"save($event)\" title='hi' id=\"a\">{{ user.name }} - {{ total + 1 }}</my-button>\n</template>"
    #expect(tokens(code, "A.vue") == [
        "template:tag",
        "my-button:tag",
        "v-if:keyword",
        "0:number",
        ":class:keyword",
        "active:property",
        "@click:keyword",
        "save:function",
        "'hi':string",
        "\"a\":string",
        "name:property",
        "1:number",
        "my-button:tag",
        "template:tag",
    ])
}

@Test func vueTagNamesKeepTheirHyphensAndTextStaysPlain() {
    let code = "<template><router-link to=\"/a\">go</router-link><p>1 < 2</p><MyCard v-for=\"c in cards\" :key=\"c.id\" /></template>"
    #expect(tokens(code, "A.vue") == [
        "template:tag",
        "router-link:tag",
        "\"/a\":string",
        "router-link:tag",
        "p:tag",
        "p:tag",
        "MyCard:tag",
        "v-for:keyword",
        "in:keyword",
        ":key:keyword",
        "id:property",
        "template:tag",
    ])
}

@Test func vueLeavesATagInsideAnHtmlCommentAlone() {
    let code = "<template><!-- <div v-if=\"x\"> --><p>a</p></template>"
    #expect(tokens(code, "A.vue") == [
        "template:tag",
        "<!-- <div v-if=\"x\"> -->:comment",
        "p:tag",
        "p:tag",
        "template:tag",
    ])
}

@Test func anUnclosedQuoteInAVueScriptStopsAtItsLine() {
    let code = "<template><p>ok</p></template>\n<script>\nconst s = \"unclosed\n</script>\n<style>.b { color: blue }</style>"
    #expect(tokens(code, "A.vue") == [
        "template:tag",
        "p:tag",
        "p:tag",
        "template:tag",
        "script:tag",
        "const:keyword",
        "\"unclosed:string",
        "script:tag",
        "style:tag",
        "style:tag",
    ])
}

@Test func vueReadsEveryScriptAndStyleBlock() {
    let code = "<script>\nexport default { name: 'A' }\n</script>\n<script setup>\nconst n = 1\n</script>\n<style scoped>\n.a { color: red !important /* c */ }\n</style>"
    #expect(tokens(code, "A.vue") == [
        "script:tag",
        "export:keyword",
        "default:keyword",
        "name:property",
        "'A':string",
        "script:tag",
        "script:tag",
        "const:keyword",
        "1:number",
        "script:tag",
        "style:tag",
        "important:keyword",
        "/* c */:comment",
        "style:tag",
    ])
}

@Test func aVueDirectiveCanSpanLinesWithoutRunningIntoTheNextAttribute() {
    let code = "<template>\n  <div :class=\"{\n    active: isOn\n  }\" id=\"x\">hi</div>\n</template>"
    #expect(tokens(code, "A.vue") == ["template:tag", "div:tag", ":class:keyword", "active:property", "\"x\":string", "div:tag", "template:tag"])
}

@Test func aComponentNamedLikeStyleIsNoStyleBlock() {
    let code = "<template><style-guide id=\"z\">x</style-guide></template>\n<script>\nconst b = 2\n</script>"
    #expect(tokens(code, "A.vue") == [
        "template:tag", "style-guide:tag", "\"z\":string", "style-guide:tag", "template:tag",
        "script:tag", "const:keyword", "2:number", "script:tag",
    ])
}

@Test func anUnclosedExpressionOrASlashStarInTextLeavesTheRestAlone() {
    let code = "<template><p>{{ a</p><p>src/*.js</p><my-card :a=\"b\"/></template>"
    #expect(tokens(code, "A.vue") == ["template:tag", "p:tag", "p:tag", "p:tag", "p:tag", "my-card:tag", ":a:keyword", "template:tag"])
}

@Test func htmlColorsItsScriptStyleCustomElementsAndDoctype() {
    let code = "<!DOCTYPE html>\n<my-app data-x='1'></my-app>\n<script type=\"module\">const a = 1</script>\n<style>p { color: red !important }</style>"
    #expect(tokens(code, "index.html") == [
        "DOCTYPE:keyword", "my-app:tag", "'1':string", "my-app:tag",
        "script:tag", "\"module\":string", "const:keyword", "1:number", "script:tag",
        "style:tag", "important:keyword", "style:tag",
    ])
}

@Test func svelteColorsItsBracesBlocksAndDirectives() {
    let code = "<script lang=\"ts\">let count = 0</script>\n{#if count > 1}<button on:click={() => count++} {disabled}>{count}</button>{/if}"
    #expect(tokens(code, "A.svelte") == [
        "script:tag", "\"ts\":string", "let:keyword", "0:number", "script:tag",
        "if:keyword", "1:number", "button:tag", "on:click:keyword", "button:tag", "if:keyword",
    ])
}

@Test func astroColorsItsFrontmatterAndExpressions() {
    let code = "---\nimport Card from './Card.astro'\nconst items = [1]\n---\n<Card client:load title={items.length} />"
    #expect(tokens(code, "index.astro") == [
        "import:keyword", "Card:type", "from:keyword", "'./Card.astro':string", "const:keyword", "1:number",
        "Card:tag", "client:load:keyword", "length:property",
    ])
}

@Test func goModColorsItsDirectivesAndComments() {
    let code = "module example.com/app\n\ngo 1.22\n\nrequire (\n\tgithub.com/a/b v1.2.3 // indirect\n)\nreplace example.com/x => ../x"
    #expect(tokens(code, "go.mod") == ["module:keyword", "go:keyword", "1.22:number", "require:keyword", "// indirect:comment", "replace:keyword"])
    #expect(Syntax.language(for: "go.work") != nil)
    #expect(Syntax.language(for: "go.sum") == nil)
    #expect(tokens("a { opacity: .5 }", "a.css") == ["5:number"])
}
