import AppKit
import SwiftUI

/// Farol's lighthouse at icon size, its two beams lit in a state's color. With no beam color it's just the tower.
/// Used by the menu bar item and the notch.
enum Lighthouse {
    static func image(beam: NSColor?, body: NSColor, size: CGFloat = 18) -> NSImage {
        let scale = size / 18
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSAffineTransform.scaled(scale).concat()
            body.setFill()
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
    }
}

extension Palette {
    /// The sidebar's color for an activity, or nil when idle.
    func color(_ activity: Session.Activity) -> NSColor? {
        switch activity {
        case .working: NSColor(working)
        case .waiting: NSColor(waiting)
        case .done: NSColor(done)
        case .idle: nil
        }
    }
}

private extension NSAffineTransform {
    static func scaled(_ factor: CGFloat) -> NSAffineTransform {
        let transform = NSAffineTransform()
        transform.scale(by: factor)
        return transform
    }
}
