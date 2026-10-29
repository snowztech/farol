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
