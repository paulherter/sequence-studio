import Foundation

/// The pointer shape a drawn panel asks for (`HostHover.cursor`); each host maps it to its own cursors: the Mac shared UI
/// to NSCursor and the Mac timeline's drawn tool cursors (`TimelineCursors`), Windows to the IDC_* system cursors and,
/// for the tool shapes, to cursors made from `DrawCursorImage`.
public enum DrawCursor: Sendable, Hashable, CaseIterable {
    case arrow, crosshair, iBeam, resizeLeftRight, resizeUpDown, openHand, closedHand, pointingHand, dragCopy, zoomIn,
         notAllowed
    /// The timeline tool cursors (the Mac `TimelineCursorKind`): edge trims, ripple and rate stretch per side, roll,
    /// slip, slide, razor and Track Select Forward.
    case trimIn, trimOut, rippleIn, rippleOut, rateIn, rateOut, roll, slip, slide, razor, trackSelect
    /// The monitor transform overlay's cursors (the Mac `OverlayCursors`): corner resize along "\" (top left to bottom
    /// right) and "/" , the four-way move, and the curved rotate arrows turned toward the handle's corner.
    case resizeDiagonalDown, resizeDiagonalUp, move
    case rotateBottomRight, rotateBottomLeft, rotateTopLeft, rotateTopRight

    /// The rotate cursor of the corner whose outward direction on screen is `angle` degrees (clockwise from +x, y down).
    public static func rotate(angle: Double) -> DrawCursor {
        var a = angle.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        switch a {
        case 0..<90: return .rotateBottomRight
        case 90..<180: return .rotateBottomLeft
        case 180..<270: return .rotateTopLeft
        default: return .rotateTopRight
        }
    }

    /// The outward direction (degrees clockwise from +x, y down) a rotate cursor turns toward; nil for the others.
    public var rotateAngle: Double? {
        switch self {
        case .rotateBottomRight: 45
        case .rotateBottomLeft: 135
        case .rotateTopLeft: 225
        case .rotateTopRight: 315
        default: nil
        }
    }

    /// The resize cursor along a handle's direction (`angle` as in `rotate(angle:)`; a direction and its opposite look
    /// the same): left-right, up-down or one of the two diagonals.
    public static func resize(angle: Double) -> DrawCursor {
        var a = angle.truncatingRemainder(dividingBy: 180)
        if a < 0 { a += 180 }
        if a < 22.5 || a >= 157.5 { return .resizeLeftRight }
        if a < 67.5 { return .resizeDiagonalDown }
        if a < 112.5 { return .resizeUpDown }
        return .resizeDiagonalUp
    }

    /// A shape the system has no cursor for: the host draws it (`DrawCursorImage`).
    public var isToolGlyph: Bool {
        switch self {
        case .trimIn, .trimOut, .rippleIn, .rippleOut, .rateIn, .rateOut, .roll, .slip, .slide, .razor, .trackSelect: true
        default: false
        }
    }

    /// `DrawCursorGlyph` has strokes for it: the tool shapes plus drag copy and zoom in, which Windows has no system
    /// cursor for (the Mac shows NSCursor's).
    public var hasDrawnGlyph: Bool { isToolGlyph || rotateAngle != nil || self == .dragCopy || self == .zoomIn }
}

/// The tool cursors as strokes in a 24 x 24 box (y down, hot spot in the middle), the Mac `TimelineCursors` glyphs
/// translated: black lines over a white halo so they read on any clip color.
public enum DrawCursorGlyph {
    public static let size: CGFloat = 24
    public static let hotSpot = CGPoint(x: 12, y: 12)
    /// Line width of the glyph; the halo is `width + halo`.
    public static let width: CGFloat = 1.6
    public static let halo: CGFloat = 2.4

    /// The polylines of `cursor` (empty for the system shapes).
    public static func strokes(_ cursor: DrawCursor) -> [[CGPoint]] {
        let c = hotSpot
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x, y: c.y + y) }
        func arrow(tipX x: CGFloat, dir: CGFloat) -> [CGPoint] { [p(x - dir * 4, -3.5), p(x, 0), p(x - dir * 4, 3.5)] }
        var out: [[CGPoint]] = []
        switch cursor {
        case .trimIn, .trimOut, .rippleIn, .rippleOut, .rateIn, .rateOut:
            // Edge bracket: a bar with serifs towards the clip (+1: the clip is on the right), arrows left and right.
            let s: CGFloat = (cursor == .trimIn || cursor == .rippleIn || cursor == .rateIn) ? 1 : -1
            out = [[p(s * 4, -7), p(0, -7), p(0, 7), p(s * 4, 7)], [p(-9, 0), p(9, 0)], arrow(tipX: -9, dir: -1), arrow(tipX: 9, dir: 1)]
            if cursor == .rippleIn || cursor == .rippleOut { out.append([p(s * 7, -4), p(s * 7, 4)]) }
            if cursor == .rateIn || cursor == .rateOut {
                for dy: CGFloat in [-3.5, 3.5] { out.append([p(s * 6, dy), p(s * 11, dy)]) }
            }
        case .trackSelect:
            out = [[p(-8, 0), p(6, 0)], arrow(tipX: 6, dir: 1), [p(9, -7), p(9, 7)]]
        case .roll:
            out = [[p(-2, -7), p(-2, 7)], [p(2, -7), p(2, 7)], [p(-10, 0), p(10, 0)], arrow(tipX: -10, dir: -1), arrow(tipX: 10, dir: 1)]
        case .slip, .slide:
            out = [[p(-4, -5), p(4, -5), p(4, 5), p(-4, 5), p(-4, -5)], [p(-10, 0), p(10, 0)],
                   arrow(tipX: -10, dir: -1), arrow(tipX: 10, dir: 1)]
            out += cursor == .slip ? [[p(0, -5), p(0, 5)]] : [[p(-7, -6), p(-7, 6)], [p(7, -6), p(7, 6)]]
        case .razor:
            // Lucide "scissors" (the Mac razor cursor's `SQIcon.toolBlade`): two rings and two blades, 20 pt in the box.
            func ring(_ cx: CGFloat, _ cy: CGFloat) -> [CGPoint] {
                (0...12).map { i in
                    let a = CGFloat(i) / 12 * 2 * .pi
                    return p(cx + 2.5 * cos(a), cy + 2.5 * sin(a))
                }
            }
            out = [ring(-5, -5), ring(-5, 5), [p(-3.2, -3.2), p(8, 7)], [p(-3.2, 3.2), p(8, -7)]]
        case .dragCopy:
            // The arrow pointer with its tip on the hot spot and a plus badge below right (NSCursor.dragCopy).
            out = [[p(0, 0), p(0, 13), p(3.2, 10), p(5.6, 15), p(7.6, 14), p(5.2, 9.2), p(9.4, 9.2), p(0, 0)],
                   [p(10, 1), p(10, 9)], [p(6, 5), p(14, 5)]]
        case .zoomIn:
            // A magnifier with a plus, the lens centered on the hot spot (Lucide "zoom-in").
            let lens = (0...16).map { i in
                let a = CGFloat(i) / 16 * 2 * .pi
                return p(6 * cos(a), 6 * sin(a))
            }
            out = [lens, [p(4.3, 4.3), p(9.5, 9.5)], [p(-3, 0), p(3, 0)], [p(0, -3), p(0, 3)]]
        case .rotateBottomRight, .rotateBottomLeft, .rotateTopLeft, .rotateTopRight:
            // A 100 degree arc turned toward the corner with an arrow head at each end (the Mac curved-arrow cursor).
            let mid = (cursor.rotateAngle ?? 45) * .pi / 180
            let half = 50.0 * .pi / 180, r: CGFloat = 8
            func pt(_ a: Double) -> CGPoint { p(r * CGFloat(cos(a)), r * CGFloat(sin(a))) }
            out = [(0...10).map { pt(mid - half + Double($0) / 10 * 2 * half) }]
            for (a, dir) in [(mid + half, 1.0), (mid - half, -1.0)] {
                // Tangent at the end, pointing away from the arc; the head's wings fold back from the tip.
                let t = (-sin(a) * dir, cos(a) * dir)
                let tip = pt(a)
                let nx = cos(a), ny = sin(a)
                func wing(_ s: Double) -> CGPoint {
                    CGPoint(x: tip.x + CGFloat(-t.0 * 4 + nx * 3 * s), y: tip.y + CGFloat(-t.1 * 4 + ny * 3 * s))
                }
                out.append([wing(1), tip, wing(-1)])
            }
        default: break
        }
        return out
    }
}

/// A tool cursor as straight-alpha RGBA pixels (rows top to bottom) at `scale` pixels per point, rendered through the
/// shared `SoftwareRenderer`: once over black and once over white, the difference gives the coverage.
public enum DrawCursorImage {
    public struct Image: Sendable, Equatable {
        public var image: RGBAImage
        /// Hot spot in pixels.
        public var hotX: Int, hotY: Int
    }

    public static func render(_ cursor: DrawCursor, scale: Float) -> Image? {
        let lines = DrawCursorGlyph.strokes(cursor)
        guard !lines.isEmpty else { return nil }
        let side = Int((Float(DrawCursorGlyph.size) * scale).rounded(.up))
        var c = Canvas(width: Float(side), height: Float(side), atlas: nil, scale: scale)
        for l in lines { c.strokePolyline(l, width: DrawCursorGlyph.width + DrawCursorGlyph.halo, .white) }
        for l in lines { c.strokePolyline(l, width: DrawCursorGlyph.width, DrawColor(0, 0, 0)) }
        let black = SoftwareRenderer.render(c.list, width: side, height: side, clear: DrawColor(0, 0, 0), atlas: nil)
        let white = SoftwareRenderer.render(c.list, width: side, height: side, clear: .white, atlas: nil)
        var px = [UInt8](repeating: 0, count: side * side * 4)
        for i in 0..<(side * side) {
            // over black: v = a * src; over white: v = a * src + 1 - a  ->  a = 1 - (white - black)
            let b = Float(black.pixels[i * 4]) / 255, w = Float(white.pixels[i * 4]) / 255
            let a = min(max(1 - (w - b), 0), 1)
            guard a > 0.004 else { continue }
            let v = UInt8(min(max(b / a, 0), 1) * 255 + 0.5)
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v
            px[i * 4 + 3] = UInt8(a * 255 + 0.5)
        }
        let hot = Int((Float(DrawCursorGlyph.hotSpot.x) * scale).rounded())
        return Image(image: RGBAImage(width: side, height: side, pixels: px), hotX: hot, hotY: hot)
    }
}
