import Foundation
import Testing
@testable import FarolCore

private func folder() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("farol-open-path-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    return root.path
}

@Test func directoryIsUsedAsIs() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(atPath: root) }
    #expect(OpenPath.directory(for: root) == root)
}

@Test func fileUsesItsParentFolder() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(atPath: root) }
    #expect(OpenPath.directory(for: root + "/file.txt") == root)
}

@Test func missingPathIsIgnored() {
    #expect(OpenPath.directory(for: "/does/not/exist") == nil)
}

@Test func fallbackIsHome() {
    #expect(OpenPath.fallback == NSHomeDirectory())
}

@Test func aLinkOpensItsFileAtTheLineAgentsPrint() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let file = root + "/file.txt"
    #expect(OpenPath.file(link: "file.txt", in: root)?.path == file)
    #expect(OpenPath.file(link: "file.txt:42", in: root)?.line == 42)
    #expect(OpenPath.file(link: "./file.txt:42:7", in: root).map { "\($0.path):\($0.line ?? 0)" } == "\(file):42")
    #expect(OpenPath.file(link: file + ":3", in: nil)?.line == 3)
    #expect(OpenPath.file(link: "file://" + file, in: nil)?.path == file)
}

@Test func linksTheMacShouldOpenAreLeftAlone() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(atPath: root) }
    #expect(OpenPath.file(link: "https://farol.sh/docs", in: root) == nil)
    #expect(OpenPath.file(link: "mailto:hi@farol.sh", in: root) == nil)
    #expect(OpenPath.file(link: "missing.txt:4", in: root) == nil)
    #expect(OpenPath.file(link: ".", in: root) == nil)
}
