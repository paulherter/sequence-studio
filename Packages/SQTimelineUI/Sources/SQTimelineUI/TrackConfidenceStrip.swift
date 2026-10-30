import AppKit
import SQCore


extension ClipDrawing {
    /// Weak stretches only (amber, `Theme.Colors.warning`) along the clip's bottom edge, clipped to the clip's rounded body
    /// so the corners stay round; nothing where tracking holds (a full-width green strip read as an audio lane, DECISIONS
    /// 2026-10-07 "Magic mask tracking quality and corrections"). `weak` come from `weakRanges`.
    public static func drawTrackConfidence(weak: [ClosedRange<CGFloat>], rect: CGRect, visible: CGRect) {
        guard !weak.isEmpty, let cg = NSGraphicsContext.current?.cgContext, rect.width >= 12, rect.height >= bodyMinHeight else { return }
        let body = rect.insetBy(dx: 0, dy: 1)
        let radius = min(Theme.Radius.small, body.height / 2)
        let h = TrackConfidenceStrip.height
        cg.saveGState()
        cg.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.clip()
        cg.setFillColor(Theme.Colors.warning.cgColor)
        for r in weak {
            let seg = CGRect(x: rect.minX + r.lowerBound, y: body.maxY - h, width: r.upperBound - r.lowerBound, height: h).intersection(visible)
            if !seg.isNull { cg.fill(seg) }
            // Marker where a stretch begins: a 2 px tick rising above the strip.
            let tick = CGRect(x: rect.minX + r.lowerBound, y: body.maxY - h - 3, width: 2, height: h + 3).intersection(visible)
            if !tick.isNull { cg.fill(tick) }
        }
        cg.restoreGState()
    }
}
