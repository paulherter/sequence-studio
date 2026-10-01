import CoreGraphics
import Foundation
import SSCore

/// Pure geometry and drag reducers for the Program monitor's transform overlay.
///
/// Spaces (all y down):
/// - view: points in the overlay view (`viewRect` is where the sequence canvas is drawn, aspect-fitted by the host).
/// - offset: sequence px relative to the canvas centre (what `ClipTransform.position` uses).
/// - local: layer px relative to the aspect-fitted layer centre, before scale/rotation (what `anchor` uses).
///
/// Model: `offset = position + R(rotation) * S(scale) * (local - anchor)`. The anchor therefore sits at `position`
/// on the canvas (Premiere: Position is where the anchor point lies); scale and rotation pivot on it.
///
/// Premiere behaviour, decided here:
/// - Drag body: move (Shift = lock to the dominant axis).
/// - Any handle scales uniformly while the clip's Uniform Scale is on (the default). With it off, side handles change
///   width, top and bottom handles height, corners both freely; Shift then locks the proportions.
///   Scaling pivots on the anchor (Premiere default); Option pivots on the opposite handle instead (edge stays put).
/// - Just outside a corner (ring from the handle out to `rotateZone`): rotate about the anchor, clockwise positive;
///   Shift snaps the result to 45 degrees.
/// - The anchor wins every grab within `anchorRadius` of its crosshair, also at the picture centre.
/// - Anchor crosshair: moving it does not move the picture (position is compensated).
/// Scale is clamped to `minimumScale` (never negative).
public struct TransformOverlayGeometry: Sendable, Equatable {
    public enum Handle: Sendable, Hashable, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        /// Direction of the handle in layer space: -1, 0 or 1 per axis (y down).
        public var direction: (x: Double, y: Double) {
            switch self {
            case .topLeft: (-1, -1)
            case .top: (0, -1)
            case .topRight: (1, -1)
            case .right: (1, 0)
            case .bottomRight: (1, 1)
            case .bottom: (0, 1)
            case .bottomLeft: (-1, 1)
            case .left: (-1, 0)
            }
        }
        public var isCorner: Bool { direction.x != 0 && direction.y != 0 }
    }

    public enum Hit: Sendable, Hashable {
        case anchor
        case handle(Handle)
        /// Rotation zone outside a corner.
        case rotate(Handle)
        case body
    }

    public struct ScaleModifiers: Sendable, Hashable {
        /// Uniform Scale off: locks the proportions. Ignored while Uniform Scale is on.
        public var shift: Bool
        /// Pivot on the opposite handle instead of the anchor.
        public var option: Bool
        /// The clip's Uniform Scale flag (Effect Controls). On: every handle scales both axes by the same factor.
        public var uniformScale: Bool
        public init(shift: Bool = false, option: Bool = false, uniformScale: Bool = true) {
            self.shift = shift; self.option = option; self.uniformScale = uniformScale
        }
    }

    public static let minimumScale = 0.0001
    public static let handleRadius: CGFloat = 6
    public static let anchorRadius: CGFloat = 10
    /// Rotation zone: outside the quad, past the corner handle, within this distance of a corner.
    public static let rotateZone: CGFloat = 28
    public static let rotationSnapDegrees = 45.0

    public var sequenceSize: CGSize
    public var viewRect: CGRect
    /// Width / height of the media. The layer is aspect-fitted into the sequence.
    public var mediaAspect: Double
    /// Upright source size in px. Set = Scale is relative to source pixels (Premiere: the layer is drawn at this size at
    /// scale 1, see `SequenceFormat.fitScale`); nil = the layer is aspect-fitted at scale 1 (legacy, tests).
    public var mediaPixelSize: CGSize?
    public var transform: ClipTransform

    public init(sequenceSize: CGSize, viewRect: CGRect, mediaAspect: Double, transform: ClipTransform,
                mediaPixelSize: CGSize? = nil) {
        self.sequenceSize = sequenceSize; self.viewRect = viewRect
        self.mediaAspect = mediaAspect; self.transform = transform; self.mediaPixelSize = mediaPixelSize
    }

    // MARK: Spaces

    public var viewScale: Double { sequenceSize.width > 0 ? Double(viewRect.width / sequenceSize.width) : 1 }

    /// Aspect-fitted layer size in sequence px (scale 1).
    public var fittedSize: CGSize {
        if let m = mediaPixelSize, m.width > 0, m.height > 0 { return m }
        guard sequenceSize.width > 0, sequenceSize.height > 0, mediaAspect > 0 else { return .zero }
        let seqAspect = Double(sequenceSize.width / sequenceSize.height)
        if mediaAspect >= seqAspect {
            return CGSize(width: sequenceSize.width, height: sequenceSize.width / mediaAspect)
        }
        return CGSize(width: sequenceSize.height * mediaAspect, height: sequenceSize.height)
    }

    public func viewPoint(fromOffset o: Vec2) -> CGPoint {
        CGPoint(x: viewRect.midX + CGFloat(o.x * viewScale), y: viewRect.midY + CGFloat(o.y * viewScale))
    }
    public func offset(fromView p: CGPoint) -> Vec2 {
        Vec2(Double(p.x - viewRect.midX) / viewScale, Double(p.y - viewRect.midY) / viewScale)
    }

    private func rotate(_ v: Vec2, degrees: Double) -> Vec2 {
        let a = degrees * .pi / 180
        return Vec2(v.x * cos(a) - v.y * sin(a), v.x * sin(a) + v.y * cos(a))
    }

    /// Layer-local point to offset space, using `t`.
    public func offset(fromLocal l: Vec2, _ t: ClipTransform) -> Vec2 {
        let d = l - t.anchor
        return t.position + rotate(Vec2(d.x * t.scale.x, d.y * t.scale.y), degrees: t.rotation)
    }
    public func viewPoint(fromLocal l: Vec2) -> CGPoint { viewPoint(fromOffset: offset(fromLocal: l, transform)) }

    /// Offset-space delta to layer-local delta (inverse of rotation and scale) under `t`.
    private func localDelta(fromOffsetDelta d: Vec2, _ t: ClipTransform) -> Vec2 {
        let r = rotate(d, degrees: -t.rotation)
        return Vec2(r.x / max(t.scale.x, Self.minimumScale), r.y / max(t.scale.y, Self.minimumScale))
    }

    // MARK: Drawing geometry

    /// Corners in view coords: top-left, top-right, bottom-right, bottom-left of the layer.
    public var quad: [CGPoint] {
        let s = fittedSize
        let hw = Double(s.width) / 2, hh = Double(s.height) / 2
        return [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { viewPoint(fromLocal: Vec2($0.0, $0.1)) }
    }

    public func localPoint(of h: Handle) -> Vec2 {
        let s = fittedSize
        return Vec2(h.direction.x * Double(s.width) / 2, h.direction.y * Double(s.height) / 2)
    }
    public func viewPoint(of h: Handle) -> CGPoint { viewPoint(fromLocal: localPoint(of: h)) }
    public var anchorViewPoint: CGPoint { viewPoint(fromOffset: transform.position) }

    // MARK: Hit testing

    /// Direction of a handle on screen, degrees clockwise from +x (y down), for cursors: from the layer centre outward.
    public func viewAngle(of h: Handle) -> Double {
        let c = viewPoint(fromLocal: .zero), p = viewPoint(of: h)
        return atan2(Double(p.y - c.y), Double(p.x - c.x)) * 180 / .pi
    }

    /// The anchor always has priority within `anchorRadius` of its crosshair (it sits on the centre of the picture by
    /// default, and must still be grabbable there). `anchorAlways: false` is only for tests of the other zones.
    public func hitTest(_ p: CGPoint, anchorAlways: Bool = true) -> Hit? {
        if anchorAlways, hypot(p.x - anchorViewPoint.x, p.y - anchorViewPoint.y) <= Self.anchorRadius { return .anchor }
        var best: (Handle, CGFloat)?
        for h in Handle.allCases {
            let hp = viewPoint(of: h)
            let d = hypot(p.x - hp.x, p.y - hp.y)
            if d <= Self.handleRadius, d < (best?.1 ?? .infinity) { best = (h, d) }
        }
        if let best { return .handle(best.0) }
        if Self.contains(quad, p) { return .body }
        var near: (Handle, CGFloat)?
        for h in Handle.allCases where h.isCorner {
            let hp = viewPoint(of: h)
            let d = hypot(p.x - hp.x, p.y - hp.y)
            if d <= Self.rotateZone, d < (near?.1 ?? .infinity) { near = (h, d) }
        }
        return near.map { .rotate($0.0) }
    }

    /// Convex polygon containment, either winding.
    static func contains(_ q: [CGPoint], _ p: CGPoint) -> Bool {
        var sign = 0
        for i in 0..<q.count {
            let a = q[i], b = q[(i + 1) % q.count]
            let c = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            let s = c > 0 ? 1 : (c < 0 ? -1 : 0)
            if s != 0 {
                if sign == 0 { sign = s } else if sign != s { return false }
            }
        }
        return true
    }

    // MARK: Drag reducers (self.transform is the transform at gesture start)

    public func moved(from start: CGPoint, to p: CGPoint, lockAxis: Bool = false) -> ClipTransform {
        var dx = Double(p.x - start.x) / viewScale, dy = Double(p.y - start.y) / viewScale
        if lockAxis { if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 } }
        var t = transform
        t.position = transform.position + Vec2(dx, dy)
        return t
    }

    public func scaled(handle h: Handle, from start: CGPoint, to p: CGPoint,
                       modifiers m: ScaleModifiers = .init()) -> ClipTransform {
        let t = transform
        let hl = localPoint(of: h)
        let dir = h.direction
        // Pivot in local space.
        let fixed: Vec2 = m.option
            ? Vec2(dir.x != 0 ? -hl.x : t.anchor.x, dir.y != 0 ? -hl.y : t.anchor.y)
            : t.anchor
        let v = hl - fixed   // local vector pivot -> handle (unscaled)
        let fixedOffset = offset(fromLocal: fixed, t)
        // The handle follows the pointer, keeping the grab offset.
        let target = viewPoint(of: h)
        let eff = CGPoint(x: target.x + (p.x - start.x), y: target.y + (p.y - start.y))
        let d = rotate(offset(fromView: eff) - fixedOffset, degrees: -t.rotation)   // scaled local vector pivot -> pointer

        var sx = t.scale.x, sy = t.scale.y
        if m.uniformScale || m.shift {
            // Proportions locked: one factor for both axes, measured along the handle (corner: projection on its diagonal).
            var k: Double?
            if h.isCorner {
                let cur = Vec2(v.x * t.scale.x, v.y * t.scale.y)
                let den = cur.x * cur.x + cur.y * cur.y
                if den > 0 { k = (d.x * cur.x + d.y * cur.y) / den }
            } else if dir.x != 0, abs(v.x) > 1e-9 {
                k = d.x / v.x / max(t.scale.x, Self.minimumScale)
            } else if dir.y != 0, abs(v.y) > 1e-9 {
                k = d.y / v.y / max(t.scale.y, Self.minimumScale)
            }
            if let k { sx = t.scale.x * k; sy = t.scale.y * k }
        } else {
            if dir.x != 0, abs(v.x) > 1e-9 { sx = d.x / v.x }
            if dir.y != 0, abs(v.y) > 1e-9 { sy = d.y / v.y }
        }
        sx = max(sx, Self.minimumScale); sy = max(sy, Self.minimumScale)

        var out = t
        out.scale = Vec2(sx, sy)
        // Keep the pivot where it was on the canvas.
        let shifted = rotate(Vec2((fixed.x - t.anchor.x) * sx, (fixed.y - t.anchor.y) * sy), degrees: t.rotation)
        out.position = fixedOffset - shifted
        return out
    }

    /// `continuingFrom`: the rotation last produced in this gesture, so multi-turn drags do not wrap at 180 degrees.
    public func rotated(from start: CGPoint, to p: CGPoint, snap: Bool = false,
                        continuingFrom last: Double? = nil) -> ClipTransform {
        let c = anchorViewPoint
        let a0 = atan2(Double(start.y - c.y), Double(start.x - c.x))
        let a1 = atan2(Double(p.y - c.y), Double(p.x - c.x))
        var delta = (a1 - a0) * 180 / .pi
        delta -= 360 * (delta / 360).rounded()   // nearest branch to 0 ...
        if let last {                            // ... or to the previous result
            let prevDelta = last - transform.rotation
            delta += 360 * ((prevDelta - delta) / 360).rounded()
        }
        var r = transform.rotation + delta
        if snap { r = (r / Self.rotationSnapDegrees).rounded() * Self.rotationSnapDegrees }
        var t = transform
        t.rotation = r
        return t
    }

    /// Moves the anchor with the pointer; position is compensated so the picture stays where it is.
    public func anchorMoved(from start: CGPoint, to p: CGPoint) -> ClipTransform {
        let dOff = Vec2(Double(p.x - start.x) / viewScale, Double(p.y - start.y) / viewScale)
        var t = transform
        t.anchor = transform.anchor + localDelta(fromOffsetDelta: dOff, transform)
        t.position = transform.position + dOff
        return t
    }
}

// MARK: - Motion path

/// Motion path of a position track in view coords, plus drag reducers for its keys and tangents.
public struct MotionPathGeometry: Sendable, Equatable {
    public struct Key: Sendable, Hashable {
        public var id: UUID
        public var point: CGPoint
        /// Absolute view positions of the tangent handles (equal to `point` when the tangent is zero).
        public var inHandle: CGPoint
        public var outHandle: CGPoint
        public var hasInTangent: Bool
        public var hasOutTangent: Bool
    }
    public enum Hit: Sendable, Hashable {
        case key(UUID)
        case inTangent(UUID)
        case outTangent(UUID)
    }

    public static let keyRadius: CGFloat = 6
    public static let tangentRadius: CGFloat = 5

    public var viewRect: CGRect
    public var sequenceSize: CGSize
    /// One polyline per segment, view coords. Hold segments have a single point.
    public var segments: [[CGPoint]]
    public var keys: [Key]

    public init(track: KeyframeTrack<Vec2>, sequenceSize: CGSize, viewRect: CGRect, samplesPerSegment: Int = 32) {
        self.viewRect = viewRect; self.sequenceSize = sequenceSize
        let scale = sequenceSize.width > 0 ? Double(viewRect.width / sequenceSize.width) : 1
        func toView(_ v: Vec2) -> CGPoint {
            CGPoint(x: viewRect.midX + CGFloat(v.x * scale), y: viewRect.midY + CGFloat(v.y * scale))
        }
        segments = track.motionPath(samplesPerSegment: samplesPerSegment).map { $0.points.map(toView) }
        keys = track.keys.map {
            Key(id: $0.id, point: toView($0.value),
                inHandle: toView($0.value + $0.inTangent), outHandle: toView($0.value + $0.outTangent),
                hasInTangent: $0.inTangent != .zero, hasOutTangent: $0.outTangent != .zero)
        }
    }

    var viewScale: Double { sequenceSize.width > 0 ? Double(viewRect.width / sequenceSize.width) : 1 }

    /// Tangent handles are hit targets for the selected key or when they are non-zero.
    public func hitTest(_ p: CGPoint, selectedKey: UUID? = nil) -> Hit? {
        func near(_ a: CGPoint, _ r: CGFloat) -> Bool { hypot(p.x - a.x, p.y - a.y) <= r }
        for k in keys {
            if (k.id == selectedKey || k.hasOutTangent), k.outHandle != k.point, near(k.outHandle, Self.tangentRadius) {
                return .outTangent(k.id)
            }
            if (k.id == selectedKey || k.hasInTangent), k.inHandle != k.point, near(k.inHandle, Self.tangentRadius) {
                return .inTangent(k.id)
            }
        }
        for k in keys where near(k.point, Self.keyRadius) { return .key(k.id) }
        return nil
    }

    /// New position value for a key dragged to `p` (view coords).
    public func keyValue(at p: CGPoint) -> Vec2 {
        Vec2(Double(p.x - viewRect.midX) / viewScale, Double(p.y - viewRect.midY) / viewScale)
    }

    /// Tangent (offset from the key value, sequence px) for a handle dragged to `p`.
    public func tangent(forKey id: UUID, handleAt p: CGPoint) -> Vec2 {
        guard let k = keys.first(where: { $0.id == id }) else { return .zero }
        return Vec2(Double(p.x - k.point.x) / viewScale, Double(p.y - k.point.y) / viewScale)
    }

    /// Dragging one handle of a key: the other handle mirrors it (smooth key) unless `independent` (Option).
    public func tangents(forKey id: UUID, dragging side: Hit, to p: CGPoint,
                         independent: Bool, current: (in: Vec2, out: Vec2)) -> (in: Vec2, out: Vec2) {
        let t = tangent(forKey: id, handleAt: p)
        switch side {
        case .outTangent: return (independent ? current.in : t * -1, t)
        case .inTangent: return (t, independent ? current.out : t * -1)
        case .key: return current
        }
    }
}
