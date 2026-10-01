import AppKit

/// Premiere-like timeline cursors, drawn in code (no assets). Black glyphs with a white halo so they read on any clip colour.
@MainActor
public enum TimelineCursors {
    private static var cache: [TimelineCursorKind: NSCursor] = [:]

    public static func cursor(for kind: TimelineCursorKind) -> NSCursor {
        if let c = cache[kind] { return c }
        let c: NSCursor
        switch kind {
        case .hand: c = .openHand
        case .razor: c = razor()
        default: c = glyph(kind)
        }
        cache[kind] = c
        return c
    }

    private static let size = NSSize(width: 24, height: 24)

    private static func image(_ draw: @escaping (CGContext) -> Void) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(ctx)
            return true
        }
    }

    /// Strokes `path` twice: a wide white halo, then the black line.
    private static func stroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat = 1.6) {
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.addPath(path); ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(width + 2.4); ctx.strokePath()
        ctx.addPath(path); ctx.setStrokeColor(NSColor.black.cgColor); ctx.setLineWidth(width); ctx.strokePath()
    }

    private static func arrow(_ p: CGMutablePath, tip: CGPoint, dir: CGFloat) {
        p.move(to: CGPoint(x: tip.x - dir * 4, y: tip.y + 3.5)); p.addLine(to: tip); p.addLine(to: CGPoint(x: tip.x - dir * 4, y: tip.y - 3.5))
    }

    /// Edge bracket: a bar with a serif towards the clip (`serif` +1 = clip on the right) and arrows left and right.
    private static func glyph(_ kind: TimelineCursorKind) -> NSCursor {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let img = image { ctx in
            let p = CGMutablePath()
            switch kind {
            case .trimIn, .trimOut, .rippleIn, .rippleOut, .rateIn, .rateOut:
                let serif: CGFloat = (kind == .trimIn || kind == .rippleIn || kind == .rateIn) ? 1 : -1
                p.move(to: CGPoint(x: c.x, y: c.y - 7)); p.addLine(to: CGPoint(x: c.x, y: c.y + 7))            // bar
                p.move(to: CGPoint(x: c.x, y: c.y + 7)); p.addLine(to: CGPoint(x: c.x + serif * 4, y: c.y + 7)) // serifs
                p.move(to: CGPoint(x: c.x, y: c.y - 7)); p.addLine(to: CGPoint(x: c.x + serif * 4, y: c.y - 7))
                p.move(to: CGPoint(x: c.x - 9, y: c.y)); p.addLine(to: CGPoint(x: c.x + 9, y: c.y))             // shaft
                arrow(p, tip: CGPoint(x: c.x - 9, y: c.y), dir: -1)
                arrow(p, tip: CGPoint(x: c.x + 9, y: c.y), dir: 1)
                if kind == .rippleIn || kind == .rippleOut {                                                    // ripple: second bar
                    let x = c.x + serif * 7
                    p.move(to: CGPoint(x: x, y: c.y - 4)); p.addLine(to: CGPoint(x: x, y: c.y + 4))
                }
                if kind == .rateIn || kind == .rateOut {                                                        // rate stretch: speed ticks
                    for dy: CGFloat in [-3.5, 3.5] {
                        p.move(to: CGPoint(x: c.x + serif * 6, y: c.y + dy)); p.addLine(to: CGPoint(x: c.x + serif * 11, y: c.y + dy))
                    }
                }
            case .roll:
                p.move(to: CGPoint(x: c.x - 2, y: c.y - 7)); p.addLine(to: CGPoint(x: c.x - 2, y: c.y + 7))
                p.move(to: CGPoint(x: c.x + 2, y: c.y - 7)); p.addLine(to: CGPoint(x: c.x + 2, y: c.y + 7))
                p.move(to: CGPoint(x: c.x - 10, y: c.y)); p.addLine(to: CGPoint(x: c.x + 10, y: c.y))
                arrow(p, tip: CGPoint(x: c.x - 10, y: c.y), dir: -1)
                arrow(p, tip: CGPoint(x: c.x + 10, y: c.y), dir: 1)
            case .slip, .slide:
                p.addRect(CGRect(x: c.x - 4, y: c.y - 5, width: 8, height: 10))                                  // the clip
                p.move(to: CGPoint(x: c.x - 10, y: c.y)); p.addLine(to: CGPoint(x: c.x + 10, y: c.y))
                arrow(p, tip: CGPoint(x: c.x - 10, y: c.y), dir: -1)
                arrow(p, tip: CGPoint(x: c.x + 10, y: c.y), dir: 1)
                if kind == .slip {                                                                                // slip: marks inside
                    p.move(to: CGPoint(x: c.x, y: c.y - 5)); p.addLine(to: CGPoint(x: c.x, y: c.y + 5))
                } else {                                                                                          // slide: outer bars
                    p.move(to: CGPoint(x: c.x - 7, y: c.y - 6)); p.addLine(to: CGPoint(x: c.x - 7, y: c.y + 6))
                    p.move(to: CGPoint(x: c.x + 7, y: c.y - 6)); p.addLine(to: CGPoint(x: c.x + 7, y: c.y + 6))
                }
            default: break
            }
            stroke(ctx, p)
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: c.x, y: c.y))
    }

    private static func razor() -> NSCursor {
        let base = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Razor")
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        func tinted(_ color: NSColor) -> NSImage? {
            base?.withSymbolConfiguration(cfg.applying(.init(paletteColors: [color])))
        }
        let img = image { _ in
            let rect = NSRect(x: 2, y: 2, width: 20, height: 20)
            if let halo = tinted(.white) {
                for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1)] { halo.draw(in: rect.offsetBy(dx: dx, dy: dy)) }
            }
            tinted(.black)?.draw(in: rect)
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 12, y: 12))
    }
}
