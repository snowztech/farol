import AppKit
import SwiftUI

/// A lamp in the menu bar with the most urgent state across sessions, so agents are visible from any app.
/// Its menu lists the sessions, and choosing one brings Farol to it.
final class MenuBarStatus: NSObject, NSMenuDelegate {
    var onSelect: ((Session) -> Void)?

    private let store: SessionStore
    private var item: NSStatusItem?
    private var palette: Palette

    init(store: SessionStore, palette: Palette) {
        self.store = store
        self.palette = palette
        super.init()
    }

    /// Shows or removes the item, following the setting.
    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
            refresh()
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    func apply(_ palette: Palette) {
        self.palette = palette
        refresh()
    }

    /// Redraws the lamp. Called whenever a session's activity changes.
    func refresh() {
        guard let button = item?.button else { return }
        let activities = store.sessions.map(\.activity)
        let top: Session.Activity = activities.contains(.waiting) ? .waiting
            : activities.contains(.working) ? .working
            : activities.contains(.done) ? .done : .idle
        button.image = lighthouse(top)
        button.toolTip = summary(activities)
    }

    // MARK: Menu

    /// Built each time it opens, so it always matches the sessions.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for session in store.ordered {
            let item = NSMenuItem(title: session.displayName, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session
            item.image = lamp(session.activity, size: 8)
            if let state = label(session.activity) {
                let title = NSMutableAttributedString(string: session.displayName + "   ")
                title.append(NSAttributedString(string: state, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
                item.attributedTitle = title
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Farol", action: #selector(openFarol), keyEquivalent: "").target = self
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        NSApp.activate(ignoringOtherApps: true)
        onSelect?(session)
    }

    @objc private func openFarol() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.isVisible || $0.isMiniaturized }?.makeKeyAndOrderFront(nil)
    }

    // MARK: Drawing

    /// Farol's lighthouse, its two beams lit in the state's color. Idle, it's just the tower, like any menu bar icon.
    /// Drawn in the menu bar's own text color, which the drawing picks up each time it renders, so it suits light and dark.
    private func lighthouse(_ activity: Session.Activity) -> NSImage {
        let beam: NSColor? = switch activity {
        case .working: NSColor(palette.working)
        case .waiting: NSColor(palette.waiting)
        case .done: NSColor(palette.done)
        case .idle: nil
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.labelColor.setFill()
            // Tower, narrowing towards the top, on a wider base.
            let tower = NSBezierPath()
            tower.move(to: NSPoint(x: 6, y: 2.5))
            tower.line(to: NSPoint(x: 12, y: 2.5))
            tower.line(to: NSPoint(x: 10.6, y: 10.5))
            tower.line(to: NSPoint(x: 7.4, y: 10.5))
            tower.close()
            tower.fill()
            NSBezierPath(rect: NSRect(x: 4.5, y: 1.2, width: 9, height: 1.3)).fill()
            // Lamp room and roof.
            NSBezierPath(rect: NSRect(x: 7.6, y: 11.3, width: 2.8, height: 2.4)).fill()
            let roof = NSBezierPath()
            roof.move(to: NSPoint(x: 7.1, y: 14.3))
            roof.line(to: NSPoint(x: 10.9, y: 14.3))
            roof.line(to: NSPoint(x: 9, y: 16.4))
            roof.close()
            roof.fill()
            // The beams, pointing at the lamp like the app icon's.
            guard let beam else { return true }
            beam.setStroke()
            for side in [CGFloat(-1), 1] {
                let path = NSBezierPath()
                path.lineWidth = 1.6
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: NSPoint(x: 9 + side * 6.8, y: 14.6))
                path.line(to: NSPoint(x: 9 + side * 3.6, y: 12.5))
                path.line(to: NSPoint(x: 9 + side * 6.8, y: 10.4))
                path.stroke()
            }
            return true
        }
        return image
    }

    /// A filled dot in the sidebar's color for each state, and a hollow template circle when idle, so it follows the menu bar's look.
    private func lamp(_ activity: Session.Activity, size: CGFloat) -> NSImage {
        let canvas = NSSize(width: 18, height: 18)
        let color: NSColor? = switch activity {
        case .working: NSColor(palette.working)
        case .waiting: NSColor(palette.waiting)
        case .done: NSColor(palette.done)
        case .idle: nil
        }
        let image = NSImage(size: canvas, flipped: false) { rect in
            let dot = NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
            if let color {
                color.setFill()
                NSBezierPath(ovalIn: dot).fill()
            } else {
                NSColor.black.setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
        image.isTemplate = color == nil
        return image
    }

    private func label(_ activity: Session.Activity) -> String? {
        switch activity {
        case .working: "Working"
        case .waiting: "Waiting for you"
        case .done: "Done"
        case .idle: nil
        }
    }

    private func summary(_ activities: [Session.Activity]) -> String {
        let parts = [(Session.Activity.waiting, "waiting"), (.working, "working"), (.done, "done")].compactMap { activity, word in
            let count = activities.filter { $0 == activity }.count
            return count > 0 ? "\(count) \(word)" : nil
        }
        return parts.isEmpty ? "Farol" : "Farol: " + parts.joined(separator: ", ")
    }
}
