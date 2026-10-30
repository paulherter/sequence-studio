import AppKit
import SQCore

/// The thumbnail image of a chip (the item and its point math are portable: Draw/EasingPopoverDraw.swift).
extension EasingThumbnail {
    static let size = NSSize(width: 34, height: 22)

    @MainActor static func image(for item: EasingChipItem) -> NSImage {
        let samples = item.samples(count: 32)
        let img = NSImage(size: size, flipped: true) { bounds in
            let plot = bounds.insetBy(dx: 5, dy: 4)
            let pts = points(samples: samples, in: plot)
            guard let first = pts.first else { return true }
            let p = NSBezierPath(); p.lineWidth = 1.5; p.lineJoinStyle = .round; p.lineCapStyle = .round
            p.move(to: first)
            for q in pts.dropFirst() { p.line(to: q) }
            NSColor.black.setStroke(); p.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }
}
