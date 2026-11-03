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

