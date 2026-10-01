import CoreGraphics
import Foundation
import SQCore

/// The Time Remapping speed rubber band on a video clip (Premiere: Show Clip Keyframes > Time Remapping > Speed).
///
/// Layout inside the clip's lane (`ClipDrawing.waveformRect`): a strip along the top holds the speed keys (triangles) and the
/// shaded span of each speed transition; below it the rubber band is a line whose height is the speed on a log scale
/// (100 % in the middle, `octaves` doublings up and down). Pure geometry and gesture maths; `TimelineView` draws it and routes
/// the mouse, tests drive it directly with a time <-> x mapping.
///
/// Gestures (Premiere's, on our model, see docs/audit/speed-time-2.md):
/// - drag a flat part of the line up/down: speed of that segment (Shift: steps of 5 %); the segment keeps its source, so the clip
///   gets shorter or longer;
/// - Cmd-click the line: add a speed key;
/// - drag a key in the strip sideways: its right half to the right (or left half to the left) opens a speed transition;
///   Option-drag moves the unsplit key; dragging one half of a split key moves that half;
/// - drag the shaded span: move the whole transition; drag the centre handle: widen or narrow it (symmetric);
/// - Delete on a key or a half removes the key / transition.
/// Transitions are linear ramps: there is no ease curve (Premiere's Bezier curve control) in this build.
public enum SpeedBand {
    /// Rows shorter than this show no band.
    public static let minRowHeight: CGFloat = 40
    /// Height of the key strip at the top of the lane.
    public static let stripHeight: CGFloat = 9
    /// Doublings between 100 % and the top / bottom of the line area (top = 16x, bottom = 1/16x).
    public static let octaves = 4.0
    static let lineGrab: CGFloat = 4
    static let keyGrab: CGFloat = 5
    static let handleGrab: CGFloat = 6

    public static func isAvailable(rowHeight: CGFloat) -> Bool { rowHeight >= minRowHeight }

    /// The strip for keys and transitions.
    public static func strip(in lane: CGRect) -> CGRect { CGRect(x: lane.minX, y: lane.minY, width: lane.width, height: min(stripHeight, lane.height / 2)) }
    /// The area the line moves in (below the strip).
    public static func lineArea(in lane: CGRect) -> CGRect {
        let s = strip(in: lane)
        return CGRect(x: lane.minX, y: s.maxY + 2, width: lane.width, height: max(lane.height - s.height - 4, 1))
    }

    /// y of a speed ratio (1 = 100 %), flipped coordinates (up = smaller y). Clamped to the area.
    public static func y(forSpeed speed: Double, in area: CGRect) -> CGFloat {
        let o = min(max(log2(max(speed, 1e-6)), -octaves), octaves)
        return area.midY - CGFloat(o / octaves) * area.height / 2
    }

    /// Speed ratio at a y (inverse of `y(forSpeed:)`), within 1/16x ... 16x and the 1 % ... 10000 % of `ClipSpeed`.
    public static func speed(forY y: CGFloat, in area: CGRect) -> Double {
        guard area.height > 0 else { return 1 }
        let f = Double((area.midY - y) / (area.height / 2))
        return min(max(pow(2, min(max(f, -1), 1) * octaves), 0.01), 100)
    }

    /// Typed-in precision: Shift snaps the percentage to steps of 5 %.
    public static func snappedPercent(_ percent: Double, steps: Bool) -> Double {
        let p = max(percent, 1)
        return steps ? max((p / 5).rounded() * 5, 5) : p.rounded()
    }

    public static func label(speed: Double) -> String {
        var s = String(format: "%.0f", speed * 100)
        if s == "0" { s = "1" }
        return s + "%"
    }

    // MARK: Layout

    /// x of every segment boundary (`count + 1` entries) for a clip that starts at `start`.
    public static func boundaryXs(keys: SpeedKeys, clipStart: Time, x: (Time) -> CGFloat) -> [CGFloat] {
        keys.boundaries.map { x(clipStart + $0) }
    }

    /// Polyline of the rubber band (a ramp is sampled; speeds interpolate linearly in time, so the log-scale curve bends).
    public static func linePoints(keys: SpeedKeys, clipStart: Time, lane: CGRect, x: (Time) -> CGFloat) -> [CGPoint] {
        let area = lineArea(in: lane)
        var pts: [CGPoint] = []
        let starts = keys.boundaries
        for (i, s) in keys.segments.enumerated() {
            let x0 = x(clipStart + starts[i]), x1 = x(clipStart + starts[i + 1])
            if !s.isRamp {
                let y = y(forSpeed: s.speedValue(at: .zero), in: area)
                pts.append(CGPoint(x: x0, y: y)); pts.append(CGPoint(x: x1, y: y))
            } else {
                let n = max(Int(min(abs(x1 - x0) / 4, 24)), 4)
                for k in 0...n {
                    let f = Double(k) / Double(n)
                    let t = Time(Int64((f * 1_000_000).rounded()), 1_000_000)
                    let local = Time(s.duration.value * t.value, s.duration.timescale * t.timescale)
                    pts.append(CGPoint(x: x0 + (x1 - x0) * CGFloat(f), y: y(forSpeed: s.speedValue(at: local), in: area)))
                }
            }
        }
        return pts
    }

    public struct KeyMark: Equatable, Sendable {
        /// Boundary index (1 ..< segments.count).
        public var boundary: Int
        public var x: CGFloat
        /// True when the boundary belongs to a speed transition (a half of a split key).
        public var isHalf: Bool
        /// Which side the half faces: a ramp starts at its left half's boundary.
        public var isLeftHalf: Bool
    }
    public struct RampMark: Equatable, Sendable {
        public var segment: Int
        public var x0: CGFloat, x1: CGFloat
        /// Centre handle on the line.
        public var handle: CGPoint
    }

    public static func keyMarks(keys: SpeedKeys, clipStart: Time, x: (Time) -> CGFloat) -> [KeyMark] {
        let b = keys.boundaries
        var out: [KeyMark] = []
        for i in 1..<max(keys.segments.count, 1) {
            let left = keys.segments[i - 1], right = keys.segments[i]
            out.append(KeyMark(boundary: i, x: x(clipStart + b[i]), isHalf: left.isRamp || right.isRamp, isLeftHalf: right.isRamp))
        }
        return out
    }

    public static func rampMarks(keys: SpeedKeys, clipStart: Time, lane: CGRect, x: (Time) -> CGFloat) -> [RampMark] {
        let area = lineArea(in: lane), b = keys.boundaries
        return keys.segments.enumerated().compactMap { i, s in
            guard s.isRamp else { return nil }
            let x0 = x(clipStart + b[i]), x1 = x(clipStart + b[i + 1])
            let mid = s.speedValue(at: Time(s.duration.value, s.duration.timescale * 2))
            return RampMark(segment: i, x0: x0, x1: x1, handle: CGPoint(x: (x0 + x1) / 2, y: y(forSpeed: mid, in: area)))
        }
    }

    // MARK: Hit testing

    public enum Hit: Equatable, Sendable {
        /// A flat part of the line: change its speed.
        case segment(Int)
        /// A key (boundary) in the strip; may be a half of a transition.
        case key(Int)
        /// The shaded span of a transition: move it.
        case ramp(Int)
        /// The centre handle of a transition: widen / narrow it.
        case rampHandle(Int)
    }

    public static func hit(keys: SpeedKeys, clipStart: Time, lane: CGRect, at p: CGPoint, x: (Time) -> CGFloat) -> Hit? {
        let strip = strip(in: lane), area = lineArea(in: lane)
        guard p.x >= lane.minX - keyGrab, p.x <= lane.maxX + keyGrab else { return nil }
        // Handles first (on the line), then keys, ramps, segments.
        for r in rampMarks(keys: keys, clipStart: clipStart, lane: lane, x: x) where hypot(p.x - r.handle.x, p.y - r.handle.y) <= handleGrab {
            return .rampHandle(r.segment)
        }
        if p.y >= strip.minY - 2 && p.y <= strip.maxY + 2 {
            for k in keyMarks(keys: keys, clipStart: clipStart, x: x) where abs(p.x - k.x) <= keyGrab { return .key(k.boundary) }
            for r in rampMarks(keys: keys, clipStart: clipStart, lane: lane, x: x) where p.x > r.x0 && p.x < r.x1 { return .ramp(r.segment) }
            return nil
        }
        guard p.y >= area.minY - lineGrab, p.y <= area.maxY + lineGrab else { return nil }
        let starts = keys.boundaries
        for (i, s) in keys.segments.enumerated() {
            let x0 = x(clipStart + starts[i]), x1 = x(clipStart + starts[i + 1])
            guard p.x >= x0, p.x <= x1 else { continue }
            if s.isRamp {
                let f = x1 > x0 ? (p.x - x0) / (x1 - x0) : 0
                let local = Time(Int64((Double(f) * 1_000_000).rounded()) * s.duration.value, 1_000_000 * s.duration.timescale)
                if abs(p.y - y(forSpeed: s.speedValue(at: local), in: area)) <= lineGrab { return .ramp(i) }
            } else if abs(p.y - y(forSpeed: s.speedValue(at: .zero), in: area)) <= lineGrab {
                return .segment(i)
            }
        }
        return nil
    }

    // MARK: Gesture

    /// One drag on the band. `update` is pure: always computed from the keys at mouse-down, so a drag can overshoot and come back.
    public struct Gesture: Sendable {
        public let original: SpeedKeys
        public let hit: Hit?
        public let start: CGPoint
        public let lane: CGRect
        public let frameDuration: Time
        public let addKeyAt: Time?
        public let moveUnsplit: Bool
        public let steps: Bool
        let timeAt: @Sendable (CGFloat) -> Time
        let clipStart: Time

        /// `timeAt`: x -> absolute timeline time. `addKey`: Cmd-click. `option`: moves an unsplit key. `shift`: 5 % steps.
        public init(keys: SpeedKeys, clipStart: Time, hit: Hit?, start: CGPoint, lane: CGRect, frameDuration: Time,
                    addKey: Bool, option: Bool, shift: Bool, timeAt: @escaping @Sendable (CGFloat) -> Time) {
            original = keys; self.hit = hit; self.start = start; self.lane = lane; self.frameDuration = frameDuration
            moveUnsplit = option; steps = shift; self.timeAt = timeAt; self.clipStart = clipStart
            addKeyAt = addKey ? timeAt(start.x) - clipStart : nil
        }

        /// Keys after the drag reached `p`. Equal to the original when the gesture does not apply yet.
        public func update(to p: CGPoint) -> SpeedKeys {
            let fd = frameDuration
            if let t = addKeyAt { return original.addingKey(at: t, frameDuration: fd)?.keys ?? original }
            let dt = timeAt(p.x) - timeAt(start.x)
            switch hit {
            case .segment(let i)?:
                guard original.segments.indices.contains(i), !original.segments[i].isRamp else { return original }
                let pct = SpeedBand.snappedPercent(SpeedBand.speed(forY: p.y, in: SpeedBand.lineArea(in: lane)) * 100, steps: steps)
                return original.settingSpeed(ofSegment: i, to: ClipSpeed(percent: pct), frameDuration: fd)
            case .key(let b)?:
                guard original.segments.indices.contains(b), original.segments.indices.contains(b - 1) else { return original }
                let halfOfRamp = original.segments[b - 1].isRamp || original.segments[b].isRamp
                if halfOfRamp || moveUnsplit { return original.movingKey(atBoundary: b, by: dt, frameDuration: fd) ?? original }
                if dt > .zero { return original.splittingKey(atBoundary: b, takeLeft: .zero, takeRight: dt, frameDuration: fd) ?? original }
                if dt < .zero { return original.splittingKey(atBoundary: b, takeLeft: .zero - dt, takeRight: .zero, frameDuration: fd) ?? original }
                return original
            case .ramp(let i)?:
                return original.movingRamp(atSegment: i, by: dt, frameDuration: fd) ?? original
            case .rampHandle(let i)?:
                guard original.segments.indices.contains(i) else { return original }
                let w = original.segments[i].duration + dt + dt
                return original.settingRampWidth(ofSegment: i, to: w, frameDuration: fd) ?? original
            case nil:
                return original
            }
        }

        /// Text for the tooltip while dragging a segment ("Speed 250%"); nil otherwise.
        public func tooltip(at p: CGPoint) -> String? {
            guard case .segment? = hit else { return nil }
            let pct = SpeedBand.snappedPercent(SpeedBand.speed(forY: p.y, in: SpeedBand.lineArea(in: lane)) * 100, steps: steps)
            return "Speed " + SpeedBand.label(speed: pct / 100)
        }
    }

    /// Keys with the key / transition under `hit` removed (Delete). nil when `hit` is not a key or transition.
    public static func deleting(_ hit: Hit, from keys: SpeedKeys, frameDuration fd: Time) -> SpeedKeys? {
        switch hit {
        case .ramp(let i), .rampHandle(let i): return keys.removingRamp(atSegment: i, frameDuration: fd)
        case .key(let b):
            guard keys.segments.indices.contains(b), keys.segments.indices.contains(b - 1) else { return nil }
            if keys.segments[b].isRamp { return keys.removingRamp(atSegment: b, frameDuration: fd) }
            if keys.segments[b - 1].isRamp { return keys.removingRamp(atSegment: b - 1, frameDuration: fd) }
            return keys.removingKey(atBoundary: b)
        case .segment: return nil
        }
    }
}
