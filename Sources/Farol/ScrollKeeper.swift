import AppKit
import SwiftUI

/// How far each checkout's list was scrolled, kept by the panel's model so it outlives the list while the panel shows a message.
final class ScrollMemory {
    private var offsets: [String: CGFloat] = [:]

    subscript(key: String) -> CGFloat? {
        get { offsets[key] }
        set { offsets[key] = newValue }
    }
}

/// Put in the background of a scrolling list. It records the position under `key` and puts it back when the key comes back.
/// Switching sessions then returns each panel to where you left it.
struct ScrollKeeper: NSViewRepresentable {
    let key: String?
    let memory: ScrollMemory

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.follow(key, memory, in: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var key: String?
        private var followed = false
        private var memory: ScrollMemory?
        private var observer: NSObjectProtocol?
        private var growth: NSObjectProtocol?
        /// Set from the moment the key changes until the offset is back, so the swap of content isn't taken for scrolling.
        private var restoring = false
        private var attempt = 0

        deinit {
            observer.map(NotificationCenter.default.removeObserver)
            growth.map(NotificationCenter.default.removeObserver)
        }

        func follow(_ key: String?, _ memory: ScrollMemory, in view: NSView) {
            self.memory = memory
            guard !followed || key != self.key else { return }
            followed = true
            self.key = key
            restoring = true
            attempt += 1
            let current = attempt
            // Read now, before the new content's own layout can move the list and be recorded over it.
            let offset = key.flatMap { memory[$0] } ?? 0
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, attempt == current else { return }
                guard let scroll = view?.enclosingScrollView else { return finish(current) }
                observe(scroll.contentView)
                settle(scroll, at: offset, attempt: current)
            }
        }

        /// A lazy list only knows its height once its rows are laid out, so the offset is tried again while the list grows.
        private func settle(_ scroll: NSScrollView, at offset: CGFloat, attempt current: Int) {
            func place() -> Bool {
                let clip = scroll.contentView
                let room = max((scroll.documentView?.frame.height ?? 0) - clip.bounds.height, 0)
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(offset, room)))
                scroll.reflectScrolledClipView(clip)
                return room >= offset
            }
            if place() { return finish(current) }
            scroll.documentView?.postsFrameChangedNotifications = true
            growth = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.documentView,
                                                            queue: .main) { [weak self] _ in
                guard let self, attempt == current else { return }
                if place() { finish(current) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.finish(current) }
        }

        private func finish(_ current: Int) {
            guard attempt == current else { return }
            growth.map(NotificationCenter.default.removeObserver)
            growth = nil
            restoring = false
        }

        private func observe(_ clip: NSClipView) {
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak clip] _ in
                guard let self, !restoring, let key, let clip else { return }
                memory?[key] = clip.bounds.origin.y
            }
        }
    }
}

/// Where in a diff you were: the part of a file at the top of the list, and how far below its start.
/// The distance is exact, since a diff's rows all have the same height, which a pixel offset in the whole list is not.
struct DiffAnchor {
    let row: String
    let delta: CGFloat
}

final class DiffAnchors {
    var saved: [String: DiffAnchor] = [:]
}

/// Like ScrollKeeper, for the review, whose lazy list only guesses the height of rows it hasn't laid out.
/// It puts back the file part and the distance into it, jumping to the part first so it exists to measure from.
struct DiffScrollKeeper: NSViewRepresentable {
    let key: String?
    let anchors: DiffAnchors
    let jump: (String) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.jump = jump
        context.coordinator.follow(key, anchors, in: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var jump: ((String) -> Void)?
        private var key: String?
        private var followed = false
        private var anchors: DiffAnchors?
        private var observer: NSObjectProtocol?
        private var restoring = false
        private var attempt = 0

        deinit { observer.map(NotificationCenter.default.removeObserver) }

        func follow(_ key: String?, _ anchors: DiffAnchors, in view: NSView) {
            self.anchors = anchors
            guard !followed || key != self.key else { return }
            followed = true
            self.key = key
            restoring = true
            attempt += 1
            let current = attempt
            let anchor = key.flatMap { anchors.saved[$0] }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, attempt == current, let scroll = view?.enclosingScrollView else { return }
                observe(scroll.contentView)
                guard let anchor else { return finish(current) }
                // The list takes a few passes to lay out around the part, so the position is measured and set again each time.
                for (step, delay) in [0.0, 0.08, 0.25, 0.5].enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, attempt == current else { return }
                        place(anchor, in: scroll, step: step)
                        if step == 3 { finish(current) }
                    }
                }
            }
        }

        private func finish(_ current: Int) {
            if attempt == current { restoring = false }
        }

        private func place(_ anchor: DiffAnchor, in scroll: NSScrollView, step: Int) {
            guard let document = scroll.documentView else { return }
            let clip = scroll.contentView
            guard let found = Self.views(in: document).first(where: { $0.rowID == anchor.row }) else {
                return jump?(anchor.row) ?? ()
            }
            let top = found.convert(found.bounds, to: document).minY
            let room = max(document.frame.height - clip.bounds.height, 0)
            let y = min(max(top + anchor.delta, 0), room)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
        }

        private static func views(in view: NSView) -> [DiffTextView] {
            view.subviews.flatMap { ($0 as? DiffTextView).map { [$0] } ?? views(in: $0) }
        }

        private func observe(_ clip: NSClipView) {
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak clip] _ in
                guard let self, !restoring, let key, let clip, let scroll = clip.superview as? NSScrollView,
                      let document = scroll.documentView else { return }
                let top = clip.bounds.minY
                // The first part of a file that ends below the top edge is the one at the top.
                let parts = Self.views(in: document).compactMap { view -> (row: String, minY: CGFloat, maxY: CGFloat)? in
                    let rect = view.convert(view.bounds, to: document)
                    return view.rowID.map { ($0, rect.minY, rect.maxY) }
                }.sorted { $0.minY < $1.minY }
                guard let part = parts.first(where: { $0.maxY > top }) else { return }
                anchors?.saved[key] = DiffAnchor(row: part.row, delta: top - part.minY)
            }
        }
    }
}
