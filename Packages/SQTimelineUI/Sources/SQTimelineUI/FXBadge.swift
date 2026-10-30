#if canImport(AppKit)
import AppKit
import CoreText
#endif
import Foundation
import SQCore

/// The effects marker at the top right of a clip: drawn only once an effect is applied (the "none" state draws nothing).
/// V1 Quiet (DESIGN-SPEC §2): a 5 pt white dot at 85 %, 4 pt in from the top right corner; no "fx" text.
public enum FXBadge {
    public enum State: Sendable, Equatable { case none, applied }

    /// Pure draw decision. Applied = any effect in the list, a changed fixed effect (Motion, Opacity, blend mode), a color
    /// correction, or a frame hold.
    public static func state(for clip: Clip) -> State {
        guard clip.kind == .video else { return .none }
        let fresh = ClipAnimation()
        let a = clip.animation
        let motionChanged = a.position != fresh.position || a.scale != fresh.scale || a.rotation != fresh.rotation || a.anchor != fresh.anchor
        let opacityChanged = a.opacity != fresh.opacity || clip.blendMode != .normal
        if !clip.effects.isEmpty || motionChanged || opacityChanged || clip.footageColor != ClipFootageColor() || clip.holdFrame != nil { return .applied }
        return .none
    }

    /// Smallest clip width that has room for the badge.
    public static let minClipWidth: CGFloat = 16
    public static let size = CGSize(width: 5, height: 5)
    public static let inset: CGFloat = 4

    /// Where the badge sits: the top right corner of the clip, kept in view while the right end is scrolled out.
    public static func frame(clipRect: CGRect, visible: CGRect) -> CGRect? {
        guard clipRect.width >= minClipWidth else { return nil }
        let right = min(clipRect.maxX, visible.maxX) - inset
        let r = CGRect(x: right - size.width, y: clipRect.minY + inset, width: size.width, height: size.height)
        return r.minX >= clipRect.minX + inset ? r : nil
    }
}

#if canImport(AppKit)
extension ClipDrawing {
    /// Board "Clip badges": a small "fx" pill (black 50 %, radius 3, 9 pt bold) at the clip's top right.
    public static func drawFXBadge(rect: CGRect, visible: CGRect) {
        guard let cg = NSGraphicsContext.current?.cgContext, rect.width >= 40 else { return }
        let w = fxLineWidth + 6, h: CGFloat = 12
        let right = min(rect.maxX, visible.maxX) - 3
        let pill = CGRect(x: right - w, y: rect.minY + 4, width: w, height: h)
        guard pill.minX >= rect.minX + ClipDrawing.thumbnailWidth else { return }
        cg.saveGState()
        cg.setFillColor(fxPillCG)
        cg.addPath(CGPath(roundedRect: pill, cornerWidth: 3, cornerHeight: 3, transform: nil)); cg.fillPath()
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        cg.textPosition = CGPoint(x: pill.minX + 3, y: pill.minY + 9)
        CTLineDraw(fxLine, cg)
        cg.restoreGState()
    }
    /// Width the clip name gives up at the clip's right end when the badge is drawn (pill plus its 3 pt inset).
    public static func fxBadgeReserve(clipWidth: CGFloat) -> CGFloat { clipWidth >= 40 ? fxLineWidth + 6 + 3 : 0 }
    nonisolated(unsafe) private static let fxLine = CTLineCreateWithAttributedString(NSAttributedString(
        string: "fx", attributes: [.font: Theme.Typography.badge, .foregroundColor: Theme.white(1)]))
    private static let fxLineWidth = CGFloat(CTLineGetTypographicBounds(fxLine, nil, nil, nil))
    private static let fxPillCG = Theme.TimelineSkin.fxPill.cgColor

    /// The opacity rubber band: a thin line with a diamond on every key (same look as the volume band).
    public static func drawOpacityLine(clip: Clip, rect: CGRect, visible: CGRect, selected: Bool, selectedKeys: Set<UUID> = []) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let pts = OpacityLine.points(clip: clip, clipRect: rect, visible: visible)
        guard pts.count >= 2 else { return }
        cg.saveGState()
        cg.clip(to: visible.intersection(rect))
        cg.setLineWidth(1)
        cg.setStrokeColor(Theme.OnPicture.clipBadgeEdge.cgColor)
        cg.addLines(between: pts.map { CGPoint(x: $0.x, y: $0.y + 1) }); cg.strokePath()
        cg.setStrokeColor((selected ? Theme.OnPicture.clipBadgeFill : Theme.OnPicture.clipBadgeFill.withAlphaComponent(0.75)).cgColor)
        cg.addLines(between: pts); cg.strokePath()
        cg.setFillColor(Theme.OnPicture.clipBadgeFill.cgColor)
        cg.setStrokeColor(Theme.OnPicture.clipBadgeEdge.cgColor)
        let keyIDs = clip.animation.opacity.track.keys.map(\.id)
        for (i, k) in OpacityLine.keyPoints(clip: clip, clipRect: rect).enumerated() where k.x >= visible.minX - 4 && k.x <= visible.maxX + 4 {
            cg.setFillColor((selectedKeys.contains(keyIDs[i]) ? Theme.Colors.keyframeSelected : Theme.OnPicture.clipBadgeFill).cgColor)
            let d = CGMutablePath()
            d.move(to: CGPoint(x: k.x, y: k.y - 4)); d.addLine(to: CGPoint(x: k.x + 4, y: k.y))
            d.addLine(to: CGPoint(x: k.x, y: k.y + 4)); d.addLine(to: CGPoint(x: k.x - 4, y: k.y)); d.closeSubpath()
            cg.addPath(d); cg.fillPath()
            cg.addPath(d); cg.strokePath()
        }
        cg.restoreGState()
    }
}
#endif
