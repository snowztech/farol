import Foundation
import Testing
@testable import FarolCore

private func inbox(maxSize: Int = 1000) -> AttachmentInbox {
    AttachmentInbox(folder: FileManager.default.temporaryDirectory.appendingPathComponent("farol-inbox-\(UUID().uuidString)"), maxSize: maxSize)
}

private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 7, count: 96)

@Test func partsInOrderMakeOnePrivateFile() throws {
    let inbox = inbox()
    let id = UUID()
    #expect(try inbox.take(id, part: 0, of: 2, data: jpeg.prefix(50)) == nil)
    let file = try #require(try inbox.take(id, part: 1, of: 2, data: jpeg.suffix(50)))
    #expect(file.pathExtension == "jpg")
    #expect(file.deletingLastPathComponent().path == inbox.folder.path)
    #expect(try Data(contentsOf: file) == jpeg)
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test func aPartSentTwiceIsTakenOnce() throws {
    let inbox = inbox()
    let id = UUID()
    _ = try inbox.take(id, part: 0, of: 2, data: jpeg.prefix(50))
    #expect(try inbox.take(id, part: 0, of: 2, data: jpeg.prefix(50)) == nil)
    let file = try #require(try inbox.take(id, part: 1, of: 2, data: jpeg.suffix(50)))
    #expect(try Data(contentsOf: file) == jpeg)
    // The last part again, after a dropped connection, gives back the same file.
    #expect(try inbox.take(id, part: 1, of: 2, data: jpeg.suffix(50)) == file)
}

@Test func onlyAnImageUnderTheLimitIsKept() {
    let inbox = inbox(maxSize: 100)
    #expect(throws: AttachmentInbox.Problem.notAnImage) { try inbox.take(UUID(), part: 0, of: 1, data: Data("#!/bin/sh\nrm -rf ~".utf8)) }
    #expect(throws: AttachmentInbox.Problem.tooLarge) { try inbox.take(UUID(), part: 0, of: 1, data: jpeg + jpeg) }
    #expect(throws: AttachmentInbox.Problem.outOfOrder) { try inbox.take(UUID(), part: 1, of: 2, data: jpeg) }
    #expect(throws: AttachmentInbox.Problem.outOfOrder) { try inbox.take(UUID(), part: 0, of: 0, data: jpeg) }
}

@Test func pngAndHeicAreImagesToo() {
    #expect(AttachmentInbox.kind(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])) == "png")
    #expect(AttachmentInbox.kind(of: Data([0, 0, 0, 24]) + Data("ftypheic".utf8)) == "heic")
    #expect(AttachmentInbox.kind(of: Data("GIF89a......".utf8)) == nil)
}

@Test func oldPicturesAreSweptAway() throws {
    let inbox = inbox()
    let file = try #require(try inbox.take(UUID(), part: 0, of: 1, data: jpeg))
    inbox.sweep(olderThan: 3600, now: .now + 7200)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}
