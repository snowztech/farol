import AppKit
import SwiftUI

/// Put in the background of the review's list. When the search asks for a line, it scrolls the list so the line is in view.
/// The list lays out lazily, so the line is measured and the list moved again a few times while it settles.
struct RevealKeeper: NSViewRepresentable {
    let request: ReviewModel.Reveal?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.follow(request, in: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var last: UUID?

        func follow(_ request: ReviewModel.Reveal?, in view: NSView) {
            guard let request, request.id != last else { return }
            last = request.id
            for delay in [0.0, 0.08, 0.25] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                    guard let view, self.last == request.id else { return }
                    Self.place(request, in: view)
                }
            }
        }

        private static func place(_ request: ReviewModel.Reveal, in view: NSView) {
            guard let scroll = view.enclosingScrollView, let document = scroll.documentView else { return }
            for diff in diffViews(in: document) {
                guard let rect = diff.rect(ofRow: request.row, in: request.path) else { continue }
                let clip = scroll.contentView
                let top = diff.convert(rect, to: document).minY
                let room = max(document.frame.height - clip.bounds.height, 0)
                // A match already in view stays where it is, so stepping through nearby ones doesn't move the list.
                if top > clip.bounds.minY + 110, top < clip.bounds.maxY - 60 { return }
                // Below the file's pinned header, with a few lines above for context.
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(top - 110, 0), room)))
                scroll.reflectScrolledClipView(clip)
                return
            }
        }

        private static func diffViews(in view: NSView) -> [DiffTextView] {
            view.subviews.flatMap { ($0 as? DiffTextView).map { [$0] } ?? diffViews(in: $0) }
        }
    }
}
