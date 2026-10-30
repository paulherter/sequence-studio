import Foundation
import SQCore

/// The opacity rubber band on a video clip (Premiere: Opacity keyframes on the clip): a line over the picture at the
/// clip's Opacity. Cmd-click adds a key at the clicked time holding the value shown there, drag a key to move it, drag the
/// line to change the level. Pure geometry and gesture maths, the twin of `VolumeLine`; `TimelineView` draws it and routes
/// the mouse (`TimelineView+OpacityLine`).
public enum OpacityLine {
    /// Rows shorter than this show no band (too little room to grab it).
    public static let minRowHeight: CGFloat = VolumeLine.minRowHeight
    static let lineGrab: CGFloat = 4
    static let keyGrab: CGFloat = 6

    public static func isAvailable(rowHeight: CGFloat) -> Bool { rowHeight >= minRowHeight }

    /// The line is drawn (and grabbable) only when it says something: the opacity is not 100 % or it has keys. A plain clip
    /// shows nothing, selected or not (the board's selected clip has no line; the Controls panel is where opacity starts).
    public static func isVisible(clip: Clip, selected: Bool, rowHeight: CGFloat) -> Bool {
        guard clip.kind == .video, isAvailable(rowHeight: rowHeight) else { return false }
        return clip.animation.opacity.isAnimated || clip.animation.opacity.value != 1
    }

    /// The area the line moves in: the clip body below the name strip.
    public static func lane(in clipRect: CGRect) -> CGRect { ClipBodyMetrics.waveformRect(in: clipRect) }

    /// 100 % at the top of the lane, 0 % at the bottom.
    public static func y(forOpacity v: Double, in lane: CGRect) -> CGFloat {
        lane.maxY - lane.height * CGFloat(min(max(v, 0), 1))
    }

    public static func opacity(forY y: CGFloat, in lane: CGRect) -> Double {
        guard lane.height > 0 else { return 1 }
        return min(max(Double((lane.maxY - y) / lane.height), 0), 1)
    }

    public enum Hit: Equatable, Sendable {
        case key(UUID)
        /// On the line (not on a key) at this clip-local time.
        case line(atLocal: Time)
    }

    static func level(_ clip: Clip, atLocal t: Time) -> Double { min(max(clip.animation.opacity.value(atLocal: t), 0), 1) }

    public static func hit(clip: Clip, clipRect: CGRect, at p: CGPoint, geometry: TimelineGeometry) -> Hit? {
        guard clipRect.insetBy(dx: -keyGrab, dy: 0).contains(CGPoint(x: p.x, y: clipRect.midY)) else { return nil }
        let lane = lane(in: clipRect)
        guard lane.height >= 4 else { return nil }
        for k in clip.animation.opacity.track.keys {
            let kx = geometry.x(for: clip.start + k.time)
            let ky = y(forOpacity: k.value, in: lane)
            if hypot(p.x - kx, p.y - ky) <= keyGrab { return .key(k.id) }
        }
        guard clipRect.contains(CGPoint(x: p.x, y: clipRect.midY)) else { return nil }
        let local = min(max(geometry.time(atX: p.x) - clip.start, .zero), clip.duration)
        return abs(p.y - y(forOpacity: level(clip, atLocal: local), in: lane)) <= lineGrab ? .line(atLocal: local) : nil
    }

    private static func x(of t: Time, clip: Clip, rect: CGRect) -> CGFloat {
        let d = Double(clip.duration.value) / Double(clip.duration.timescale)
        let s = Double(t.value) / Double(t.timescale)
        return rect.minX + CGFloat(d > 0 ? s / d : 0) * rect.width
    }

    /// Polyline of the line inside `visible`, `step` points apart (keys are always included).
    public static func points(clip: Clip, clipRect: CGRect, visible: CGRect, step: CGFloat = 3) -> [CGPoint] {
        let lane = lane(in: clipRect)
        let x0 = max(clipRect.minX, visible.minX), x1 = min(clipRect.maxX, visible.maxX)
        guard x1 > x0, lane.height > 0 else { return [] }
        if clip.animation.opacity.track.isEmpty {
            let y = y(forOpacity: clip.animation.opacity.value, in: lane)
            return [CGPoint(x: x0, y: y), CGPoint(x: x1, y: y)]
        }
        let secPerPoint = Double(clip.duration.value) / Double(clip.duration.timescale) / Double(max(clipRect.width, 1))
        func at(_ x: CGFloat) -> CGPoint {
            let t = Time(Int64((Double(x - clipRect.minX) * secPerPoint * 1_000_000).rounded()), 1_000_000)
            return CGPoint(x: x, y: y(forOpacity: level(clip, atLocal: t), in: lane))
        }
        var xs: [CGFloat] = Array(stride(from: x0, to: x1, by: max(step, 1))) + [x1]
        xs += clip.animation.opacity.track.keys.map { x(of: $0.time, clip: clip, rect: clipRect) }.filter { $0 > x0 && $0 < x1 }
        return xs.sorted().map(at)
    }

    /// Key positions (view points) for drawing.
    public static func keyPoints(clip: Clip, clipRect: CGRect) -> [CGPoint] {
        let lane = lane(in: clipRect)
        return clip.animation.opacity.track.keys.map { CGPoint(x: x(of: $0.time, clip: clip, rect: clipRect), y: y(forOpacity: $0.value, in: lane)) }
    }
}

/// One drag on the opacity line. Always recomputes from the clip it started with, so the result depends only on where the
/// pointer is now (dragging back to the start restores the original).
public struct OpacityLineGesture {
    public let original: Clip
    private let hit: OpacityLine.Hit
    private let start: CGPoint
    private let clipRect: CGRect
    private let geometry: TimelineGeometry
    private let startClip: Clip
    private var keyID: UUID?

    /// `addKey`: Cmd-click on the line first adds a key there (holding the value shown at that time), then the drag moves it.
    public init(clip: Clip, hit: OpacityLine.Hit, start: CGPoint, clipRect: CGRect, geometry: TimelineGeometry, addKey: Bool) {
        original = clip; self.hit = hit; self.start = start; self.clipRect = clipRect; self.geometry = geometry
        var c = clip
        switch hit {
        case .key(let id): keyID = id
        case .line(let t):
            if addKey { keyID = c.addOpacityKey(atLocal: t.snapped(to: geometry.frameDuration)) }
        }
        startClip = c
    }

    public mutating func update(to p: CGPoint) -> Clip {
        if hypot(p.x - start.x, p.y - start.y) < 1 { return startClip }   // no real movement: nothing more to commit
        var c = startClip
        let lane = OpacityLine.lane(in: clipRect)
        if let id = keyID {
            c.moveOpacityKey(id, toLocal: geometry.time(atX: p.x) - c.start, value: OpacityLine.opacity(forY: p.y, in: lane),
                              frameDuration: geometry.frameDuration)
        } else if case .line(let t) = hit {
            c.shiftOpacityLine(atLocal: t, by: OpacityLine.opacity(forY: p.y, in: lane) - OpacityLine.opacity(forY: start.y, in: lane))
        }
        return c
    }
}
