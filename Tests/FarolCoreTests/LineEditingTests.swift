import Foundation
import Testing
@testable import FarolCore

/// The text after the edit, with the selection marked by [ and ], or | for a cursor.
private func apply(_ edit: LineEditing.Edit?, to text: String) -> String? {
    guard let edit else { return nil }
    let result = NSMutableString(string: text)
    result.replaceCharacters(in: edit.range, with: edit.replacement)
    if edit.selection.length == 0 {
        result.insert("|", at: edit.selection.location)
    } else {
        result.insert("]", at: NSMaxRange(edit.selection))
        result.insert("[", at: edit.selection.location)
    }
    return result as String
}

private func cursor(_ at: Int, _ length: Int = 0) -> NSRange { NSRange(location: at, length: length) }

@Test func movesLines() {
    let text = "a\nbb\nc"
    #expect(apply(LineEditing.move(text as NSString, cursor(3), up: true), to: text) == "b|b\na\nc")
    #expect(apply(LineEditing.move(text as NSString, cursor(3), up: false), to: text) == "a\nc\nb|b")
    #expect(apply(LineEditing.move(text as NSString, cursor(6), up: true), to: text) == "a\nc|\nbb")
    #expect(LineEditing.move(text as NSString, cursor(0), up: true) == nil)
    #expect(LineEditing.move(text as NSString, cursor(5), up: false) == nil)
    // Two lines selected, the selection ending at the start of the third, which stays put.
    #expect(apply(LineEditing.move(text as NSString, cursor(0, 5), up: false), to: text) == "c\n[a\nbb]")
}

@Test func duplicatesLines() {
    let text = "a\nbb\nc"
    #expect(apply(LineEditing.duplicate(text as NSString, cursor(3), up: false), to: text) == "a\nbb\nb|b\nc")
    #expect(apply(LineEditing.duplicate(text as NSString, cursor(3), up: true), to: text) == "a\nb|b\nbb\nc")
    #expect(apply(LineEditing.duplicate(text as NSString, cursor(5), up: false), to: text) == "a\nbb\nc\n|c")
}

@Test func deletesLines() {
    let text = "a\nbb\nc"
    #expect(apply(LineEditing.delete(text as NSString, cursor(3)), to: text) == "a\n|c")
    #expect(apply(LineEditing.delete(text as NSString, cursor(6)), to: text) == "a\nbb|")
    #expect(apply(LineEditing.delete("only" as NSString, cursor(2)), to: "only") == "|")
}

@Test func togglesComments() {
    let code = "func a() {\n    b()\n\n  c()\n}"
    let lines = cursor(11, 15)
    let commented = apply(LineEditing.toggleComment(code as NSString, lines, .line("//")), to: code)
    #expect(commented == "func a() {\n[  //   b()\n\n  // c()]\n}")
    let back = "func a() {\n  //   b()\n\n  // c()\n}"
    #expect(apply(LineEditing.toggleComment(back as NSString, cursor(11, 21), .line("//")), to: back) == "func a() {\n[    b()\n\n  c()]\n}")
    #expect(apply(LineEditing.toggleComment("x = 1" as NSString, cursor(2), .line("#")), to: "x = 1") == "# x |= 1")
    #expect(apply(LineEditing.toggleComment("a {}" as NSString, cursor(0), .block("/*", "*/")), to: "a {}") == "/* |a {} */")
    #expect(apply(LineEditing.toggleComment("/* a {} */" as NSString, cursor(5), .block("/*", "*/")), to: "/* a {} */") == "a |{}")
}
