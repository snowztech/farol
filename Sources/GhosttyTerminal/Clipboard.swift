import AppKit
import GhosttyKit

/// Something the user should approve before the clipboard is touched.
public struct ClipboardRequest {
    public enum Kind {
        /// Pasting text Ghostty considers unsafe, such as text with line breaks.
        case paste
        /// A program in the session asked to read the clipboard.
        case programRead
        /// A program in the session asked to set the clipboard.
        case programWrite
    }

    public let kind: Kind
    public let text: String
}

/// Bridges Ghostty's clipboard callbacks to the macOS pasteboard. Only the standard clipboard exists on macOS.
enum Clipboard {
    typealias Entry = (mime: String, data: Data)

    static func read(
        _ view: TerminalView, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int, list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let surface = view.surface else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }
        let pasteboard = NSPasteboard.general
        let entries: [Entry] = (0..<count).compactMap { i in
            guard let ptr = mimes?[i] else { return nil }
            let mime = String(cString: ptr)
            return data(for: mime, in: pasteboard).map { (mime, $0) }
        }
        let available = list ? availableMimes(in: pasteboard) : []
        if entries.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }

        complete(surface, entries, available: available, state: state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    static func write(
        _ view: TerminalView, location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int, confirm: Bool
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content else { return }
        let text = (0..<count)
            .map { content[$0] }
            .first { $0.mime.map { String(cString: $0) } == "text/plain" }
            .flatMap { entry in entry.data.map { String(decoding: Data(bytes: $0, count: entry.len), as: UTF8.self) } }
        guard let text else { return }

        let set = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        if !confirm { return set() }
        view.onClipboardRequest?(ClipboardRequest(kind: .programWrite, text: text)) { if $0 { set() } }
    }

    static func confirmRead(
        _ view: TerminalView, request: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?, kind: ghostty_clipboard_request_e
    ) {
        guard let surface = view.surface else { return }
        guard let request = request?.pointee, let handler = view.onClipboardRequest else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }

        // Ghostty's buffers only live for this call, and the user may answer later.
        let entries: [Entry] = (0..<request.contents_len).compactMap { i in
            let c = request.contents[i]
            guard let mime = c.mime, let bytes = c.data else { return nil }
            return (String(cString: mime), Data(bytes: bytes, count: c.len))
        }
        let available = (0..<request.available_len).compactMap { request.available[$0].map { String(cString: $0) } }
        let text = entries.first { $0.mime == "text/plain" }.map { String(decoding: $0.data, as: UTF8.self) } ?? ""

        handler(ClipboardRequest(kind: kind == GHOSTTY_CLIPBOARD_REQUEST_PASTE ? .paste : .programRead, text: text)) { approved in
            if approved {
                complete(surface, entries, available: available, state: state, confirmed: true)
            } else {
                ghostty_surface_deny_clipboard_request(surface, state)
            }
        }
    }

    // MARK: Pasteboard

    /// Files copied in Finder paste as their paths, ready to hand to an agent.
    private static func data(for mime: String, in pasteboard: NSPasteboard) -> Data? {
        switch mime {
        case "text/plain":
            if let urls = fileURLs(in: pasteboard), !urls.isEmpty {
                return Data(urls.map { escapedPath($0.path) }.joined(separator: " ").utf8)
            }
            return pasteboard.string(forType: .string).map { Data($0.utf8) }
        case "text/uri-list":
            guard let urls = fileURLs(in: pasteboard), !urls.isEmpty else { return nil }
            return Data(urls.map { $0.absoluteString + "\r\n" }.joined().utf8)
        default:
            return nil
        }
    }

    /// What a drop types into the terminal: the files' paths, or the dragged text.
    /// An image dropped on an agent's prompt arrives as its path, which is how agents take attachments.
    static func droppedText(in pasteboard: NSPasteboard) -> String? {
        if let urls = fileURLs(in: pasteboard), !urls.isEmpty {
            return urls.map { escapedPath($0.path) }.joined(separator: " ")
        }
        return pasteboard.string(forType: .string)
    }

    private static func availableMimes(in pasteboard: NSPasteboard) -> [String] {
        var mimes: [String] = []
        if pasteboard.string(forType: .string) != nil || fileURLs(in: pasteboard)?.isEmpty == false {
            mimes.append("text/plain")
        }
        if fileURLs(in: pasteboard)?.isEmpty == false { mimes.append("text/uri-list") }
        return mimes
    }

    private static func fileURLs(in pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    private static func escapedPath(_ path: String) -> String {
        path.reduce(into: "") { out, c in
            if " \\'\"()[]{}&;|<>$`!*?#~".contains(c) { out.append("\\") }
            out.append(c)
        }
    }

    // MARK: C bridging

    /// Copies everything into C memory for the duration of the call.
    private static func complete(
        _ surface: ghostty_surface_t, _ entries: [Entry], available: [String],
        state: UnsafeMutableRawPointer?, confirmed: Bool
    ) {
        var allocations: [UnsafeMutableRawPointer] = []
        defer { allocations.forEach { free($0) } }
        func cString(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            allocations.append(p)
            return UnsafePointer(p)
        }

        let contents: [ghostty_clipboard_content_s] = entries.map { entry in
            let buffer = malloc(max(entry.data.count, 1))!
            allocations.append(buffer)
            entry.data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: entry.data.count)
            return ghostty_clipboard_content_s(
                mime: cString(entry.mime), data: buffer.assumingMemoryBound(to: CChar.self), len: entry.data.count)
        }
        let availablePointers: [UnsafePointer<CChar>?] = available.map { cString($0) }

        contents.withUnsafeBufferPointer { contentBuffer in
            availablePointers.withUnsafeBufferPointer { availableBuffer in
                var payload = ghostty_clipboard_complete_s(
                    contents: contentBuffer.baseAddress, contents_len: contentBuffer.count,
                    available: availableBuffer.baseAddress, available_len: availableBuffer.count,
                    confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &payload, state)
            }
        }
    }
}
