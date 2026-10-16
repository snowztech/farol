import Foundation

/// Pictures a phone sends for an agent to look at, put together from their parts and kept in a folder only you can read.
/// The phone is the side to be careful with: it never names the file or says what it is, and only an image under the limit is kept.
public final class AttachmentInbox {
    public enum Problem: Error, Equatable {
        case tooLarge, notAnImage, outOfOrder
    }

    public let folder: URL
    private let maxSize: Int
    private let maxParts: Int
    /// The parts taken so far, by picture.
    private var pending: [UUID: (data: Data, next: Int, started: Date)] = [:]

    public init(folder: URL, maxSize: Int, maxParts: Int = 200) {
        self.folder = folder
        self.maxSize = maxSize
        self.maxParts = maxParts
    }

    /// Takes one part. Returns where the picture is once its last part is in, and nil before.
    /// A part sent again after a dropped connection is one already taken, and changes nothing.
    public func take(_ attachment: UUID, part: Int, of parts: Int, data: Data, now: Date = .now) throws -> URL? {
        guard (1...maxParts).contains(parts), (0..<parts).contains(part) else { throw Problem.outOfOrder }
        if let done = written(attachment) { return done }
        // Pieces of a picture the phone gave up on are not kept for ever.
        pending = pending.filter { now.timeIntervalSince($0.value.started) < 600 }
        var entry = pending[attachment] ?? (Data(), 0, now)
        if part < entry.next { return nil }
        guard part == entry.next else { throw Problem.outOfOrder }
        guard entry.data.count + data.count <= maxSize else {
            pending[attachment] = nil
            throw Problem.tooLarge
        }
        entry.data += data
        entry.next += 1
        guard entry.next == parts else {
            pending[attachment] = entry
            return nil
        }
        pending[attachment] = nil
        guard let kind = Self.kind(of: entry.data) else { throw Problem.notAnImage }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("\(attachment.uuidString).\(kind)")
        try entry.data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    /// Removes the pictures older than `age`, which an agent has long since looked at.
    public func sweep(olderThan age: TimeInterval = 7 * 24 * 3600, now: Date = .now) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(date) > age { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// The picture already written for this attachment, when its last part came twice.
    private func written(_ attachment: UUID) -> URL? {
        ["jpg", "png", "heic"].map { folder.appendingPathComponent("\(attachment.uuidString).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// What kind of image the bytes are, by how its format begins. Nil for anything else.
    static func kind(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if bytes.count == 12, String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp",
           ["heic", "heix", "mif1", "msf1", "hevc"].contains(String(decoding: bytes[8..<12], as: UTF8.self)) { return "heic" }
        return nil
    }
}
