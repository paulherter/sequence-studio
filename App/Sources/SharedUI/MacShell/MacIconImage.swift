import AppKit
import SQDrawKit
import SQUIKit

extension SQIcon {
    /// Non-template image of the icon outline (24 grid) in `color`, for cursors. Not cached.
    func image(size: CGFloat, color: NSColor, stroke: CGFloat? = nil) -> NSImage {
        let g = IconOutline.glyph(self)     // Phosphor glyphs are filled outlines on a 256 grid, own drawings strokes on 24
        let width = stroke ?? max(1.6, 22.8 / max(size, 1))
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let k = min(rect.width, rect.height) / g.grid
            ctx.scaleBy(x: k, y: k)
            ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.setStrokeColor(color.cgColor); ctx.setFillColor(color.cgColor)
            for l in g.fills where l.count > 2 { ctx.addLines(between: l); ctx.closePath() }
            ctx.fillPath(using: .winding)
            for l in g.strokes where l.count > 1 { ctx.addLines(between: l); ctx.strokePath() }
            return true
        }
    }
}
