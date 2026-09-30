import CoreGraphics
import Foundation
import SSCore

/// Value graph (property value over time) or speed graph (dv/dt over time, AE style).
public enum GraphMode: Sendable, Hashable { case value, speed }

public enum GraphHandleSide: Sendable, Hashable { case inSide, outSide }

public enum GraphHit: Sendable, Hashable {
    case key(UUID)
    case handle(UUID, GraphHandleSide)
    /// Point on the curve between two keys.
    case segment(from: UUID, to: UUID)
    case empty
}

public struct GraphInsets: Sendable, Equatable {
    public var top, left, bottom, right: CGFloat
    public init(top: CGFloat = 12, left: CGFloat = 40, bottom: CGFloat = 12, right: CGFloat = 16) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
}

/// Visible data ranges. Computed once (auto-fit) and frozen while a gesture runs, so the graph does not
/// rescale under the pointer.
public struct GraphFit: Sendable, Equatable {
    /// Seconds (clip-local).
    public var time: ClosedRange<Double>
    public var value: ClosedRange<Double>

    public init(time: ClosedRange<Double>, value: ClosedRange<Double>) { self.time = time; self.value = value }

    /// Covers keys, sampled curve (so overshoot is visible) and all handle points, plus headroom.
    public static func make(track: KeyframeTrack<Double>, mode: GraphMode, headroom: Double = 0.12) -> GraphFit {
        let keys = track.keys
        var t0 = keys.first.map { GraphMath.seconds($0.time) } ?? 0
        var t1 = keys.last.map { GraphMath.seconds($0.time) } ?? 1
        if t1 - t0 < 1e-6 { t0 -= 0.5; t1 += 0.5 }

        var ys: [Double] = []
        switch mode {
        case .value:
            ys += keys.map(\.value)
            for seg in track.valueGraph(samples: 32) { ys += seg.samples.map(\.value) }
        case .speed:
            ys.append(0)
            for seg in track.speedGraph(samples: 32) { ys += seg.samples.map(\.speed) }
        }
        for k in keys {
            for side in [GraphHandleSide.inSide, .outSide] {
                if let p = GraphMath.handlePoint(track: track, keyID: k.id, side: side, mode: mode) {
                    ys.append(p.value)
                }
            }
        }
        var lo = ys.min() ?? 0, hi = ys.max() ?? 1
        if hi - lo < 1e-9 { lo -= 1; hi += 1 }
        let pad = (hi - lo) * headroom
        return GraphFit(time: t0...t1, value: (lo - pad)...(hi + pad))
    }
}

/// A point in graph data space: seconds and value (or speed).
public struct GraphDataPoint: Sendable, Equatable {
    public var seconds: Double
    public var value: Double
}

/// Shared pure helpers (data space).
enum GraphMath {
    static func seconds(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

    /// Segment starting at `index`: left key, right key, duration, signed value delta.
    static func segment(_ track: KeyframeTrack<Double>, from index: Int)
        -> (a: Keyframe<Double>, b: Keyframe<Double>, dur: Time, delta: Double)? {
        guard index >= 0, index + 1 < track.keys.count else { return nil }
        let a = track.keys[index], b = track.keys[index + 1]
        return (a, b, b.time - a.time, b.value - a.value)
    }

    /// Y of a key glyph in the speed graph: outgoing speed, or arriving speed for the last key.
    static func keySpeed(track: KeyframeTrack<Double>, index: Int) -> Double {
        if let s = segment(track, from: index) {
            if s.a.interpolation == .hold { return 0 }
            return s.a.outHandle.speedHandle(valueDelta: s.delta, duration: s.dur).speed
        }
        if index > 0, let s = segment(track, from: index - 1) {
            if s.a.interpolation == .hold { return 0 }
            return s.b.inHandle.speedHandle(valueDelta: s.delta, duration: s.dur).speed
        }
        return 0
    }

    static func keyPoint(track: KeyframeTrack<Double>, index: Int, mode: GraphMode) -> GraphDataPoint {
        let k = track.keys[index]
        return GraphDataPoint(seconds: seconds(k.time), value: mode == .value ? k.value : keySpeed(track: track, index: index))
    }

    /// Data-space handle position; nil when the handle does not exist (no neighbour, or the segment is hold).
    static func handlePoint(track: KeyframeTrack<Double>, keyID: UUID, side: GraphHandleSide, mode: GraphMode) -> GraphDataPoint? {
        guard let i = track.keys.firstIndex(where: { $0.id == keyID }) else { return nil }
        let k = track.keys[i]
        switch side {
        case .outSide:
            guard let s = segment(track, from: i), s.a.interpolation != .hold else { return nil }
            let t = seconds(k.time) + s.a.outHandle.dx * seconds(s.dur)
            let v = mode == .value
                ? k.value + s.a.outHandle.dy * s.delta
                : s.a.outHandle.speedHandle(valueDelta: s.delta, duration: s.dur).speed
            return GraphDataPoint(seconds: t, value: v)
        case .inSide:
            guard let s = segment(track, from: i - 1), s.a.interpolation != .hold else { return nil }
            let t = seconds(k.time) - s.b.inHandle.dx * seconds(s.dur)
            let v = mode == .value
                ? k.value - s.b.inHandle.dy * s.delta
                : s.b.inHandle.speedHandle(valueDelta: s.delta, duration: s.dur).speed
            return GraphDataPoint(seconds: t, value: v)
        }
    }
}

/// Maps graph data (seconds, value/speed) to view points (origin top-left, y down) and hit-tests.
/// Pure: no AppKit.
public struct KeyframeGraphGeometry: Sendable, Equatable {
    public static let keyHitRadius: CGFloat = 8
    public static let handleHitRadius: CGFloat = 7
    public static let segmentHitDistance: CGFloat = 5
    public static let curveSamples = 48

    public var size: CGSize
    public var insets: GraphInsets
    public var fit: GraphFit
    public var mode: GraphMode

    public init(size: CGSize, insets: GraphInsets = GraphInsets(), fit: GraphFit, mode: GraphMode) {
        self.size = size; self.insets = insets; self.fit = fit; self.mode = mode
    }

    public var plot: CGRect {
        CGRect(x: insets.left, y: insets.top,
               width: max(1, size.width - insets.left - insets.right),
               height: max(1, size.height - insets.top - insets.bottom))
    }

    public var pointsPerSecond: Double { Double(plot.width) / (fit.time.upperBound - fit.time.lowerBound) }
    var valueSpan: Double { fit.value.upperBound - fit.value.lowerBound }
    public var pointsPerValue: Double { Double(plot.height) / valueSpan }

    // MARK: Mapping

    public func x(seconds: Double) -> CGFloat {
        plot.minX + CGFloat((seconds - fit.time.lowerBound) * pointsPerSecond)
    }
    public func seconds(atX x: CGFloat) -> Double {
        fit.time.lowerBound + Double(x - plot.minX) / pointsPerSecond
    }
    public func y(value: Double) -> CGFloat {
        plot.maxY - CGFloat((value - fit.value.lowerBound) * pointsPerValue)
    }
    public func value(atY y: CGFloat) -> Double {
        fit.value.lowerBound + Double(plot.maxY - y) / pointsPerValue
    }
    public func point(_ p: GraphDataPoint) -> CGPoint { CGPoint(x: x(seconds: p.seconds), y: y(value: p.value)) }
    public func data(_ p: CGPoint) -> GraphDataPoint { GraphDataPoint(seconds: seconds(atX: p.x), value: value(atY: p.y)) }

    // MARK: Layout of graph elements

    public func keyPoint(track: KeyframeTrack<Double>, index: Int) -> CGPoint {
        point(GraphMath.keyPoint(track: track, index: index, mode: mode))
    }

    public func handlePoint(track: KeyframeTrack<Double>, keyID: UUID, side: GraphHandleSide) -> CGPoint? {
        GraphMath.handlePoint(track: track, keyID: keyID, side: side, mode: mode).map(point)
    }

    /// One polyline per segment, in view coordinates.
    public func curvePolylines(track: KeyframeTrack<Double>) -> [(from: UUID, to: UUID, points: [CGPoint])] {
        let n = Self.curveSamples
        switch mode {
        case .value:
            return track.valueGraph(samples: n).map { seg in
                (seg.fromID, seg.toID, seg.samples.map { point(GraphDataPoint(seconds: $0.time, value: $0.value)) })
            }
        case .speed:
            return track.speedGraph(samples: n).map { seg in
                (seg.fromID, seg.toID, seg.samples.map { point(GraphDataPoint(seconds: $0.time, value: $0.speed)) })
            }
        }
    }

    // MARK: Hit testing

    /// Priority: handles of selected keys, keys, curve segments, empty.
    public func hitTest(_ p: CGPoint, track: KeyframeTrack<Double>, selected: Set<UUID>) -> GraphHit {
        var bestHandle: (GraphHit, CGFloat)?
        for k in track.keys where selected.contains(k.id) {
            for side in [GraphHandleSide.outSide, .inSide] {
                guard let hp = handlePoint(track: track, keyID: k.id, side: side) else { continue }
                let d = hypot(hp.x - p.x, hp.y - p.y)
                if d <= Self.handleHitRadius, d < (bestHandle?.1 ?? .infinity) { bestHandle = (.handle(k.id, side), d) }
            }
        }
        if let h = bestHandle { return h.0 }

        var bestKey: (UUID, CGFloat)?
        for i in track.keys.indices {
            let kp = keyPoint(track: track, index: i)
            let d = hypot(kp.x - p.x, kp.y - p.y)
            if d <= Self.keyHitRadius, d <= (bestKey?.1 ?? .infinity) { bestKey = (track.keys[i].id, d) }
        }
        if let k = bestKey { return .key(k.0) }

        for seg in curvePolylines(track: track) {
            var best = CGFloat.infinity
            for (a, b) in zip(seg.points, seg.points.dropFirst()) { best = min(best, Self.distance(p, toSegment: a, b)) }
            if best <= Self.segmentHitDistance { return .segment(from: seg.from, to: seg.to) }
        }
        return .empty
    }

    /// Keys whose glyph centre lies inside `rect` (marquee).
    public func keys(in rect: CGRect, track: KeyframeTrack<Double>) -> Set<UUID> {
        var out = Set<UUID>()
        for i in track.keys.indices where rect.contains(keyPoint(track: track, index: i)) { out.insert(track.keys[i].id) }
        return out
    }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        guard l2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / l2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: Grid

    /// "Nice" (1/2/5 x 10^n) horizontal grid values inside the visible value range.
    public func gridValues(targetCount: Int = 5) -> [Double] {
        let span = valueSpan
        guard span > 0, targetCount > 0 else { return [] }
        let raw = span / Double(targetCount)
        let mag = pow(10, floor(log10(raw)))
        let norm = raw / mag
        let step = (norm < 1.5 ? 1 : norm < 3.5 ? 2 : norm < 7.5 ? 5 : 10) * mag
        var v = (fit.value.lowerBound / step).rounded(.up) * step
        var out: [Double] = []
        while v <= fit.value.upperBound + step * 1e-9, out.count < 100 {
            out.append(abs(v) < step * 1e-9 ? 0 : v)
            v += step
        }
        return out
    }
}
