import AppKit
import SQCore

/// The fx badge at the top right of a clip (Premiere, "Use FX badges"): dim without effects, bright once an effect is applied.
/// Premiere's guide only describes those two states (no purple or yellow), so that is all there is; the dim state is not drawn
/// at all, to keep the timeline quiet.
public enum FXBadge {
    public enum State: Sendable, Equatable { case none, applied }

    /// Pure draw decision. Applied = any effect in the list, a changed fixed effect (Motion, Opacity, blend mode), a colour
    /// correction, or a frame hold.
    public static func state(for clip: Clip) -> State {
        guard clip.kind == .video else { return .none }
        let fresh = ClipAnimation()
        let a = clip.animation
        let motionChanged = a.position != fresh.position || a.scale != fresh.scale || a.rotation != fresh.rotation || a.anchor != fresh.anchor
        let opacityChanged = a.opacity != fresh.opacity || clip.blendMode != .normal
        if !clip.effects.isEmpty || motionChanged || opacityChanged || clip.color != .default || clip.holdFrame != nil { return .applied }
        return .none
    }

    /// Smallest clip width that has room for the badge.
    public static let minClipWidth: CGFloat = 36
    public static let size = CGSize(width: 18, height: 12)

    /// Where the badge sits: the top right corner of the clip, kept in view while the right end is scrolled out.
    public static func frame(clipRect: CGRect, visible: CGRect) -> CGRect? {
        guard clipRect.width >= minClipWidth else { return nil }
        let right = min(clipRect.maxX, visible.maxX) - 3
        let r = CGRect(x: right - size.width, y: clipRect.minY + 2, width: size.width, height: size.height)
        return r.minX >= clipRect.minX + 2 ? r : nil
    }
}

extension ClipDrawing {
    /// "fx" in a small rounded pill, bright white.
    public static func drawFXBadge(rect: CGRect, visible: CGRect) {
        guard let cg = NSGraphicsContext.current?.cgContext, let r = FXBadge.frame(clipRect: rect, visible: visible) else { return }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "fx", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white]))
        cg.saveGState()
        cg.setFillColor(Theme.black(0.55).cgColor)
        cg.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil)); cg.fillPath()
        var bounds = CGRect.zero
        bounds = CTLineGetBoundsWithOptions(line, [])
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)         // flipped view: glyphs upright
        cg.textPosition = CGPoint(x: r.midX - bounds.width / 2 - bounds.minX, y: r.midY + 3.2)
        CTLineDraw(line, cg)
        cg.restoreGState()
    }

    /// The opacity rubber band: a thin line with a diamond on every key (same look as the volume band).
    public static func drawOpacityLine(clip: Clip, rect: CGRect, visible: CGRect, selected: Bool) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let pts = OpacityLine.points(clip: clip, clipRect: rect, visible: visible)
        guard pts.count >= 2 else { return }
        cg.saveGState()
        cg.clip(to: visible.intersection(rect))
        cg.setLineWidth(1)
        cg.setStrokeColor(Theme.black(0.45).cgColor)
        cg.addLines(between: pts.map { CGPoint(x: $0.x, y: $0.y + 1) }); cg.strokePath()
        cg.setStrokeColor(Theme.white(selected ? 0.95 : 0.75).cgColor)
        cg.addLines(between: pts); cg.strokePath()
        cg.setFillColor(Theme.white(0.95).cgColor)
        cg.setStrokeColor(Theme.black(0.6).cgColor)
        for k in OpacityLine.keyPoints(clip: clip, clipRect: rect) where k.x >= visible.minX - 4 && k.x <= visible.maxX + 4 {
            let d = CGMutablePath()
            d.move(to: CGPoint(x: k.x, y: k.y - 4)); d.addLine(to: CGPoint(x: k.x + 4, y: k.y))
            d.addLine(to: CGPoint(x: k.x, y: k.y + 4)); d.addLine(to: CGPoint(x: k.x - 4, y: k.y)); d.closeSubpath()
            cg.addPath(d); cg.fillPath()
            cg.addPath(d); cg.strokePath()
        }
        cg.restoreGState()
    }
}
