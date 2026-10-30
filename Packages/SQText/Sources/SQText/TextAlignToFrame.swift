import Foundation
import SQCore

/// Premiere's six align buttons: the text block is moved so its edge (or center) meets the frame.
public enum FrameAlignment: String, Sendable, CaseIterable {
    case left, centerHorizontally, right, top, centerVertically, bottom
}

public enum TextAlignToFrame {
    /// The clip position (sequence px from the canvas center) that puts the layout's text block (`layout.bounds`: the
    /// text, or the box of area text; not the shadow or stroke) against the frame. Only the aligned axis changes.
    /// The block is scaled about the raster's center, which differs from the block's center when a shadow or stroke
    /// makes the ink lopsided; that offset is accounted for. Rotation is taken into account through the extents of the
    /// rotated block (degrees).
    public static func position(_ a: FrameAlignment, layout: TextLayoutResult, position cur: Vec2, scale: Vec2,
                                rotation: Double, canvasWidth: Double, canvasHeight: Double) -> Vec2 {
        let b = layout.bounds, ink = layout.inkBounds
        let sx = abs(scale.x), sy = abs(scale.y)
        let rad = rotation * .pi / 180
        let c = abs(cos(rad)), s = abs(sin(rad))
        let hx = (c * b.width * sx + s * b.height * sy) / 2
        let hy = (s * b.width * sx + c * b.height * sy) / 2
        // Offset of the block's center from the raster's center once scaled (zero for symmetric ink or no scaling).
        var offX = 0.0, offY = 0.0
        if rotation == 0 {
            let dx = (ink.x + ink.width / 2) - (b.x + b.width / 2), dy = (ink.y + ink.height / 2) - (b.y + b.height / 2)
            offX = dx * (1 - scale.x); offY = dy * (1 - scale.y)
        }
        var p = cur
        switch a {
        case .left: p.x = hx - canvasWidth / 2 - offX
        case .right: p.x = canvasWidth / 2 - hx - offX
        case .centerHorizontally: p.x = -offX
        case .top: p.y = hy - canvasHeight / 2 - offY
        case .bottom: p.y = canvasHeight / 2 - hy - offY
        case .centerVertically: p.y = -offY
        }
        return p
    }
}
