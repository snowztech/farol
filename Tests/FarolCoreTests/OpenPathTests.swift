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
