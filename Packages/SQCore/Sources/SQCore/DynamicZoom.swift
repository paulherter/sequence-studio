import Foundation

// Dynamic Zoom (Ken Burns): a start rectangle and an end rectangle of the clip's picture, eased over the clip, written as
// Scale and Position keys of a transform stage (`ClipEffect.dynamicZoomKind`, same stage maths as Transform / Auto
// Reframe, no render path of its own). The user's Motion values and keys are never touched.

/// A window onto the clip's upright picture, normalized: 0...1, origin top-left, y down.
public struct ZoomRect: Sendable, Hashable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    /// The whole picture (no zoom).
    public static let full = ZoomRect(x: 0, y: 0, width: 1, height: 1)
    /// A window of the picture's aspect, `1 / zoom` of its size, centered on `center` (normalized) and kept inside it.
    public static func centred(zoom: Double, on centre: Vec2 = Vec2(0.5, 0.5)) -> ZoomRect {
        let side = 1 / max(zoom.isFinite ? zoom : 1, 1)
        return ZoomRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side).clamped
    }
    /// Sizes limited to 0.01...1 (uniform: the larger side rules, so the picture's aspect is kept), moved inside the picture.
    public var clamped: ZoomRect {
        let raw = max(width.isFinite ? width : 1, height.isFinite ? height : 1)
        let side = min(max(raw, 0.01), 1)
        let cx = x.isFinite ? x + width / 2 : 0.5, cy = y.isFinite ? y + height / 2 : 0.5
        return ZoomRect(x: min(max(cx - side / 2, 0), 1 - side), y: min(max(cy - side / 2, 0), 1 - side), width: side, height: side)
    }
    /// Scale (1 = 100 %) at which this window fills the frame.
    public var zoom: Double { 1 / clamped.width }
}

/// Corner of a window (picture space, y down).
public enum ZoomCorner: Sendable, Hashable, CaseIterable {
    case topLeft, topRight, bottomRight, bottomLeft
    var direction: (x: Double, y: Double) {
        switch self {
        case .topLeft: (-1, -1)
        case .topRight: (1, -1)
        case .bottomRight: (1, 1)
        case .bottomLeft: (-1, 1)
        }
    }
}

extension ZoomRect {
    /// Moved by `d` (normalized), same size, kept inside the picture.
    public func moved(by d: Vec2) -> ZoomRect {
        let r = clamped
        return ZoomRect(x: r.x + d.x, y: r.y + d.y, width: r.width, height: r.height).clamped
    }
    /// The corner dragged to `p` (normalized), the opposite corner fixed. Uniform: the larger distance rules (picture aspect
    /// kept); the window stays inside the picture and keeps at least 1 % of its size.
    public func resized(corner: ZoomCorner, to p: Vec2) -> ZoomRect {
        let r = clamped, d = corner.direction
        let fx = d.x > 0 ? r.x : r.x + r.width, fy = d.y > 0 ? r.y : r.y + r.height
        let room = min(d.x > 0 ? 1 - fx : fx, d.y > 0 ? 1 - fy : fy)
        let want = max(abs(p.x - fx), abs(p.y - fy))
        let side = min(max(want, 0.01), max(room, 0.01))
        return ZoomRect(x: d.x > 0 ? fx : fx - side, y: d.y > 0 ? fy : fy - side, width: side, height: side).clamped
    }
    /// Resized to `zoom` (1 = whole picture) about its center, kept inside the picture.
    public func withZoom(_ zoom: Double) -> ZoomRect {
        let r = clamped
        return .centred(zoom: zoom, on: Vec2(r.x + r.width / 2, r.y + r.height / 2))
    }
}

/// How the zoom moves between the two rectangles.
public enum ZoomEase: String, Sendable, Hashable, CaseIterable {
    case linear, easeIn, easeOut, easeInOut

    var handles: (out: EaseHandle, in: EaseHandle) {
        switch self {
        case .linear: (.linear, .linear)
        case .easeIn: (EaseHandle(dx: 0.6, dy: 0), .linear)
        case .easeOut: (.linear, EaseHandle(dx: 0.6, dy: 0))
        case .easeInOut: (EaseHandle(dx: 0.5, dy: 0), EaseHandle(dx: 0.5, dy: 0))
        }
    }
}

extension ClipEffect {
    public static let dynamicZoomKind = "dynamicZoom"
}

public enum DynamicZoom {
    /// Stage Scale (%) and Position (px of the clip's frame from its center) that show `rect` full frame.
    /// The stage maps p to s p + pos, so the picture point at the frame center is q = -pos / s.
    public static func stageValues(for rect: ZoomRect, picture: Vec2) -> (scalePercent: Double, position: Vec2) {
        let r = rect.clamped, s = 1 / r.width
        let c = Vec2((r.x + r.width / 2 - 0.5) * picture.x, (r.y + r.height / 2 - 0.5) * picture.y)
        return (s * 100, Vec2(-s * c.x, -s * c.y))
    }

    /// The Dynamic Zoom stage: keys at clip-local 0 and `duration`, eased as `ease`. nil when the two windows are the same
    /// (nothing to animate) or the duration / picture is empty.
    public static func effect(from start: ZoomRect, to end: ZoomRect, duration: Time, picture: Vec2,
                              ease: ZoomEase = .easeInOut, id: UUID = UUID()) -> ClipEffect? {
        guard duration > .zero, picture.x > 0, picture.y > 0, start.clamped != end.clamped else { return nil }
        let a = stageValues(for: start, picture: picture), b = stageValues(for: end, picture: picture)
        let h = ease.handles
        let kind: Interpolation = ease == .linear ? .linear : .bezier
        func track(_ v0: Double, _ v1: Double) -> AnimatedProperty<Double> {
            AnimatedProperty(v0, track: KeyframeTrack(keys: [
                Keyframe(time: .zero, value: v0, interpolation: kind, inHandle: .linear, outHandle: h.out),
                Keyframe(time: duration, value: v1, interpolation: kind, inHandle: h.in, outHandle: .linear),
            ]))
        }
        var e = ClipEffect.make(kind: ClipEffect.dynamicZoomKind)!
        e.id = id
        e.parameters[ClipEffect.stageScaleKey] = track(a.scalePercent, b.scalePercent)
        e.parameters[ClipEffect.stagePositionXKey] = track(a.position.x, b.position.x)
        e.parameters[ClipEffect.stagePositionYKey] = track(a.position.y, b.position.y)
        return e
    }

    /// The two windows (and ease) the clip's Dynamic Zoom stage shows at its first and last Scale key. nil without a stage or
    /// when it is not a two-key stage written by `apply` (the user may have edited it in Effect Controls).
    public static func windows(of clip: Clip, picture: Vec2) -> (start: ZoomRect, end: ZoomRect, ease: ZoomEase)? {
        guard picture.x > 0, picture.y > 0, let e = clip.effect(ofKind: ClipEffect.dynamicZoomKind),
              let sc = e.parameters[ClipEffect.stageScaleKey], sc.track.keys.count == 2,
              let px = e.parameters[ClipEffect.stagePositionXKey], let py = e.parameters[ClipEffect.stagePositionYKey] else { return nil }
        let t0 = sc.track.keys[0].time, t1 = sc.track.keys[1].time
        func window(_ t: Time) -> ZoomRect {
            let s = max(sc.value(atLocal: t) / 100, 1)
            let cx = 0.5 + (-px.value(atLocal: t) / s) / picture.x, cy = 0.5 + (-py.value(atLocal: t) / s) / picture.y
            return ZoomRect(x: cx - 0.5 / s, y: cy - 0.5 / s, width: 1 / s, height: 1 / s)
        }
        let k = sc.track.keys
        let ease = ZoomEase.allCases.first { $0.handles.out == k[0].outHandle && $0.handles.in == k[1].inHandle } ?? .easeInOut
        return (window(t0), window(t1), ease)
    }

    /// Writes (or replaces) the clip's Dynamic Zoom stage. False when `effect(...)` has nothing to write.
    @discardableResult
    public static func apply(to clip: inout Clip, from start: ZoomRect, to end: ZoomRect, picture: Vec2,
                             ease: ZoomEase = .easeInOut) -> Bool {
        let existing = clip.effects.firstIndex { $0.kind == ClipEffect.dynamicZoomKind }
        guard let e = effect(from: start, to: end, duration: clip.duration, picture: picture, ease: ease,
                             id: existing.map { clip.effects[$0].id } ?? UUID()) else { return false }
        if let i = existing { clip.effects[i] = e } else { clip.effects.append(e) }
        return true
    }
}

extension EffectTransformStage {
    /// Written by Dynamic Zoom only (one per clip, replaced on the next run); `EffectCatalog.spec(for:)` knows it.
    public static let dynamicZoomSpec = EffectSpec(kind: ClipEffect.dynamicZoomKind, title: "Dynamic Zoom", params: params(shutter: false),
                                                   pairs: EffectParamPair.stagePairs)
}
