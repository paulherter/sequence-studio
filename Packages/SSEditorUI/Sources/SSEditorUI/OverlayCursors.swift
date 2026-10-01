import AppKit

/// Cursors of the Program monitor's transform overlay, drawn from SF Symbols (white with a dark halo, so they read on
/// any picture): a curved-arrow rotate cursor turned toward its corner, a double arrow turned along the handle, a
/// four-way move arrow. Cached per 15-degree step.
@MainActor
public enum OverlayCursors {
    private static var cache: [String: NSCursor] = [:]
    private static let step = 15.0

    /// Rotate cursor for the corner whose outward direction on screen is `angle` degrees (clockwise from +x, y down).
    public static func rotate(angle: Double) -> NSCursor {
        let a = quantized(angle, period: 360)
        return cached("rot\(a)") { image(symbols: ["arrow.trianglehead.2.clockwise.rotate.90", "arrow.clockwise"], rotation: Double(a) + 45) }
    }

    /// Double arrow along a handle's direction (`angle` as above; direction and its opposite look the same).
    public static func resize(angle: Double) -> NSCursor {
        let a = quantized(angle, period: 180)
        return cached("rs\(a)") { image(symbols: ["arrow.left.and.right"], rotation: Double(a)) }
    }

    public static var move: NSCursor {
        cached("move") { image(symbols: ["arrow.up.and.down.and.arrow.left.and.right"], rotation: 0) }
    }

    private static func quantized(_ angle: Double, period: Double) -> Int {
        var a = angle.truncatingRemainder(dividingBy: period)
        if a < 0 { a += period }
        return Int((a / step).rounded()) * Int(step) % Int(period)
    }

    private static func cached(_ key: String, _ make: () -> (NSImage, NSPoint)) -> NSCursor {
        if let c = cache[key] { return c }
        let (img, hot) = make()
        let c = NSCursor(image: img, hotSpot: hot)
        cache[key] = c
        return c
    }

    /// The symbol image used for a cursor (also for tests and the offscreen render).
    static func image(symbols: [String], rotation degrees: Double, size: CGFloat = 26) -> (NSImage, NSPoint) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        let base = symbols.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }.first?
            .withSymbolConfiguration(cfg)
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let base else { return true }
            let s = base.size
            let r = NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: CGFloat(-degrees * .pi / 180))     // the image space is y up: clockwise on screen is negative
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
            func tinted(_ c: NSColor) -> NSImage {
                let t = NSImage(size: s)
                t.lockFocus()
                base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
                c.set()
                NSRect(origin: .zero, size: s).fill(using: .sourceAtop)
                t.unlockFocus()
                return t
            }
            let dark = tinted(NSColor.black.withAlphaComponent(0.85)), light = tinted(.white)
            for (dx, dy) in [(-1.2, 0.0), (1.2, 0), (0, -1.2), (0, 1.2), (-0.9, -0.9), (0.9, 0.9), (-0.9, 0.9), (0.9, -0.9)] {
                dark.draw(in: r.offsetBy(dx: dx, dy: dy))
            }
            light.draw(in: r)
            return true
        }
        return (img, NSPoint(x: size / 2, y: size / 2))
    }
}
