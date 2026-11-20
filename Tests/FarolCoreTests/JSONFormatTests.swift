import Foundation
import Testing
@testable import FarolCore

@Test func formatsJSONKeepingOrderAndStrings() {
    let minified = #"{"z":1,"a":[true,null,{}],"s":"a, {b}: [c] \"d\" // e","e":[],"n":{"k":-1.5e3}}"#
    #expect(JSONFormat.pretty(minified) == """
    {
      "z": 1,
      "a": [
        true,
        null,
        {}
      ],
      "s": "a, {b}: [c] \\"d\\" // e",
      "e": [],
      "n": {
        "k": -1.5e3
      }
    }

    """)
    let pretty = JSONFormat.pretty(minified)!
    #expect(JSONFormat.pretty(pretty) == pretty)
    #expect(JSONFormat.minified(pretty) == minified)
    #expect(JSONFormat.pretty("[ 1 ,\n\t2 ]") == "[\n  1,\n  2\n]\n")
}

@Test func keepsCommentsAndTrailingCommas() {
    let source = """
    // tsconfig
    {"compilerOptions": { /* strict */ "strict": true, // always
    "target": "es2022",},
      /* paths
         below */
      "include": ["src",]}
    """
    let pretty = """
    // tsconfig
    {
      "compilerOptions": { /* strict */
        "strict": true, // always
        "target": "es2022",
      },
      /* paths
         below */
      "include": [
        "src",
      ]
    }

    """
    #expect(JSONFormat.problem(source) == nil)
    #expect(JSONFormat.pretty(source) == pretty)
    #expect(JSONFormat.pretty(pretty) == pretty)
    let minified = JSONFormat.minified(source)!
    #expect(minified == #"/* tsconfig */{"compilerOptions":{/* strict */"strict":true,/* always */"target":"es2022",},/* paths"# + "\n     below */" + #""include":["src",]}"#)
    #expect(JSONFormat.problem(minified) == nil)
}

@Test func leavesWhatIsNotJSONAlone() {
    #expect(JSONFormat.problem("{\"a\": 1}") == nil)
    #expect(JSONFormat.problem("{\"a\": 1 \"b\": 2}")?.hasPrefix("line 1, column") == true)
    #expect(JSONFormat.pretty("{\"a\": }") == nil)
    #expect(JSONFormat.minified("{") == nil)
    #expect(JSONFormat.pretty("") == nil)
}
