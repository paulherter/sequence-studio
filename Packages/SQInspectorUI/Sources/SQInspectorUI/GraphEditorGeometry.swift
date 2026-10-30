#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// One property in the Graph Editor: its speed curve, its color slot (one color per property) and its display units.
public struct GraphEditorCurve: Sendable, Equatable {
    public var property: PropertyID
    public var title: String
    public var curve: SpeedOverlayCurve
    public var colorIndex: Int
    /// Native -> display units (Opacity and Scale x100); the hover readout shows display units per second.
    public var scale: Double
    public var unit: String
    public init(property: PropertyID, title: String, curve: SpeedOverlayCurve, colorIndex: Int, scale: Double = 1, unit: String = "") {
        self.property = property; self.title = title; self.curve = curve; self.colorIndex = colorIndex
        self.scale = scale; self.unit = unit
    }
}

public enum GraphEditorHit: Sendable, Equatable {
    case key(SummaryMember)
    case handle(SummaryMember, KeySide)
    case empty
}

/// Maps the speed curves to view points (origin top-left, y down) and hit-tests. Pure.
/// x: the keyframe lanes' mapping (`KeyframeLaneGeometry`), so keys sit under the ruler exactly as in the lanes.
/// y: one shared RELATIVE speed axis for every curve: speed / the segment's average speed (Steady = flat 1x, Smooth =
/// a bell to about 1.5-2x, 0 at the plot bottom). The same ease therefore looks the same on every property, whatever its
/// units; this is exactly what `EaseHandle` stores (dy/dx). Real units appear in the hover readout.
public struct GraphEditorGeometry: Sendable, Equatable {
    public static let keyHitRadius: CGFloat = 7
    public static let handleHitRadius: CGFloat = 9
    public static let hoverRadius: CGFloat = 6
    public static let topInset: CGFloat = 12
    /// The toolbar sits at the bottom of the graph area, under the plot.
    public static let toolbarHeight: CGFloat = 28
    public static let bottomInset: CGFloat = toolbarHeight + 8
    /// The axis always shows at least 0...2.2x, so Steady (1x) and a normal Smooth fit without rescaling.
    public static let minTop = 2.2

    public var lane: KeyframeLaneGeometry
    public var height: CGFloat
    public var curves: [GraphEditorCurve]
    /// Relative speed at the bottom (always 0) and top of the plot.
    public var range: ClosedRange<Double>

    public init(lane: KeyframeLaneGeometry, height: CGFloat, curves: [GraphEditorCurve]) {
        self.lane = lane; self.height = height; self.curves = curves
        var hi = 0.0
        for c in curves {
            for seg in c.curve.segments {
                guard let avg = Self.average(c, seg) else { continue }
                for s in seg.samples { hi = max(hi, abs(s.speed) / avg) }
            }
            for h in c.curve.handles { hi = max(hi, abs(Self.relative(h))) }
        }
        range = 0...max(hi * 1.1, Self.minTop)
    }

    /// Never shrinks the axis below `other`'s top (used while a drag runs, so the plot does not jump under the pointer).
    public func growing(from other: GraphEditorGeometry) -> GraphEditorGeometry {
        var g = self
        g.range = 0...max(range.upperBound, other.range.upperBound)
        return g
    }

    public var plotTop: CGFloat { Self.topInset }
    public var plotBottom: CGFloat { max(height - Self.bottomInset, plotTop + 1) }

    public func y(speed v: Double) -> CGFloat {
        let f = (v - range.lowerBound) / (range.upperBound - range.lowerBound)
        return plotBottom - CGFloat(f) * (plotBottom - plotTop)
    }
    public func speed(atY y: CGFloat) -> Double {
        let f = Double((plotBottom - y) / (plotBottom - plotTop))
        return range.lowerBound + f * (range.upperBound - range.lowerBound)
    }

    // MARK: Relative speed

    /// Average |speed| of a segment (native units per second); nil for Hold and zero-span segments.
    static func average(_ c: GraphEditorCurve, _ seg: SpeedGraphSegment) -> Double? {
        let h = c.curve.handles.first { ($0.keyID == seg.fromID && $0.side == .outgoing) || ($0.keyID == seg.toID && $0.side == .incoming) }
        guard let h, h.segmentSeconds > 0 else { return nil }
        let avg = abs(h.span) / h.segmentSeconds
        return avg > 1e-12 ? avg : nil
    }
    /// A handle's speed relative to its segment's average (= EaseHandle slope dy/dx).
    static func relative(_ h: SpeedOverlayCurve.Handle) -> Double {
        let avg = h.segmentSeconds > 0 ? abs(h.span) / h.segmentSeconds : 0
        return avg > 1e-12 ? h.speed / avg : 0
    }

    public func curve(_ p: PropertyID) -> GraphEditorCurve? { curves.first { $0.property == p } }

    /// A key sits at its outgoing speed (the incoming one for the last key); 0 next to Hold.
    public func keyPoint(_ c: GraphEditorCurve, _ k: SpeedOverlayCurve.Key) -> CGPoint {
        let h = c.curve.handles.first { $0.keyID == k.id && $0.side == .outgoing } ?? c.curve.handles.first { $0.keyID == k.id }
        return CGPoint(x: lane.x(seconds: k.seconds), y: y(speed: h.map { abs(Self.relative($0)) } ?? 0))
    }

    /// Handle position: x = key ± influence x a third of the segment (influence 1 stops at one third, short of the
    /// neighbor key, as in Premiere), y = its relative speed. Drawn, hit and dragged at the same point (no offset, no jump).
    public func handlePoint(_ c: GraphEditorCurve, _ h: SpeedOverlayCurve.Handle) -> CGPoint? {
        guard let k = c.curve.keys.first(where: { $0.id == h.keyID }) else { return nil }
        let dir: Double = h.side == .outgoing ? 1 : -1
        let s = k.seconds + dir * h.influence * GraphMath.handleReach * h.segmentSeconds
        return CGPoint(x: lane.x(seconds: s), y: y(speed: abs(Self.relative(h))))
    }
    public func handleTruePoint(_ c: GraphEditorCurve, _ h: SpeedOverlayCurve.Handle) -> CGPoint? { handlePoint(c, h) }

    /// One drawn segment: its points and the factor from relative speed to display units per second.
    public struct Line: Sendable, Equatable {
        public var points: [CGPoint]
        public var unitsPerRelative: Double
    }

    /// Drawn segments of a curve; a curve without keys, or a zero-span segment, is a flat line at 0. Hold draws nothing.
    public func lines(_ c: GraphEditorCurve) -> [Line] {
        if c.curve.keys.isEmpty { return [Line(points: [CGPoint(x: 0, y: plotBottom), CGPoint(x: lane.width, y: plotBottom)], unitsPerRelative: 0)] }
        return c.curve.segments.compactMap { seg in
            guard let first = seg.samples.first, let last = seg.samples.last else { return nil }
            guard let avg = Self.average(c, seg) else {
                // Hold: nothing; zero span (both keys equal): flat at 0.
                let isHold = !c.curve.handles.contains { $0.keyID == seg.fromID && $0.side == .outgoing }
                return isHold ? nil : Line(points: [CGPoint(x: lane.x(seconds: first.time), y: plotBottom),
                                                    CGPoint(x: lane.x(seconds: last.time), y: plotBottom)], unitsPerRelative: 0)
            }
            return Line(points: seg.samples.map { CGPoint(x: lane.x(seconds: $0.time), y: y(speed: abs($0.speed) / avg)) },
                        unitsPerRelative: avg * c.scale)
        }
    }
    public func polylines(_ c: GraphEditorCurve) -> [[CGPoint]] { lines(c).map(\.points) }

    /// Curve under the pointer (nearest within `hoverRadius` vertically) and its real speed there, display units/s.
    public func hover(at p: CGPoint) -> (property: PropertyID, speed: Double)? {
        var best: (PropertyID, Double, CGFloat)?
        for c in curves {
            for line in lines(c) {
                for (a, b) in zip(line.points, line.points.dropFirst()) where a.x <= p.x && p.x <= b.x {
                    let f = b.x > a.x ? (p.x - a.x) / (b.x - a.x) : 0
                    let y = a.y + f * (b.y - a.y)
                    let d = abs(y - p.y)
                    if d <= Self.hoverRadius, d < (best?.2 ?? .infinity) { best = (c.property, speed(atY: y) * line.unitsPerRelative, d) }
                }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Round relative speeds for the y-axis labels and horizontal grid lines (about four lines).
    public func speedTicks() -> [Double] {
        let step = Self.niceStep(range.upperBound / 4)
        guard step > 0 else { return [] }
        return stride(from: step, through: range.upperBound, by: step).map { $0 }
    }

    /// Times (clip-local seconds) of the vertical grid lines, about every `spacing` points.
    public func timeTicks(spacing: CGFloat = 90) -> [Double] {
        guard lane.pointsPerSecond > 0 else { return [] }
        let step = Self.niceStep(Double(spacing) / lane.pointsPerSecond)
        guard step > 0 else { return [] }
        let start = (lane.viewStart / step).rounded(.up) * step
        return stride(from: start, through: lane.viewStart + lane.viewSpan, by: step).map { $0 }
    }

    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 0 }
        let mag = pow(10, floor(log10(raw)))
        let n = raw / mag
        return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * mag
    }

    /// Priority: handles of selected keys, then keys (nearest wins), else empty.
    public func hitTest(_ p: CGPoint, selected: Set<SummaryMember>) -> GraphEditorHit {
        var best: (GraphEditorHit, CGFloat)?
        for c in curves {
            for h in c.curve.handles where selected.contains(SummaryMember(property: c.property, keyID: h.keyID)) {
                guard let hp = handlePoint(c, h) else { continue }
                let d = hypot(hp.x - p.x, hp.y - p.y)
                if d <= Self.handleHitRadius, d < (best?.1 ?? .infinity) {
                    best = (.handle(SummaryMember(property: c.property, keyID: h.keyID), h.side), d)
                }
            }
        }
        if let b = best { return b.0 }
        for c in curves {
            for k in c.curve.keys {
                let kp = keyPoint(c, k)
                let d = hypot(kp.x - p.x, kp.y - p.y)
                if d <= Self.keyHitRadius, d < (best?.1 ?? .infinity) { best = (.key(SummaryMember(property: c.property, keyID: k.id)), d) }
            }
        }
        return best?.0 ?? .empty
    }

    /// Every key drawn on the same spot as `m` (keys of several properties at one time and speed, e.g. two eased keys
    /// at 0): a click takes the whole stack.
    public func stack(of m: SummaryMember) -> Set<SummaryMember> {
        guard let c = curve(m.property), let k = c.curve.keys.first(where: { $0.id == m.keyID }) else { return [m] }
        let p = keyPoint(c, k)
        var out: Set<SummaryMember> = [m]
        for c in curves {
            for k in c.curve.keys {
                let q = keyPoint(c, k)
                if abs(q.x - p.x) < 1.5, abs(q.y - p.y) < 1.5 { out.insert(SummaryMember(property: c.property, keyID: k.id)) }
            }
        }
        return out
    }

    /// Keys whose marker lies inside `rect` (marquee), across all curves.
    public func members(in rect: CGRect) -> Set<SummaryMember> {
        var out = Set<SummaryMember>()
        for c in curves {
            for k in c.curve.keys where rect.contains(keyPoint(c, k)) { out.insert(SummaryMember(property: c.property, keyID: k.id)) }
        }
        return out
    }

    /// The handle a drag to `target` (view point) gives: influence from the horizontal distance to the key, relative
    /// speed (= slope) from the height. Influence is kept in 1...100 %.
    public func dragHandle(_ m: SummaryMember, side: KeySide, to target: CGPoint) -> EaseHandle? {
        guard let c = curve(m.property), let h = c.curve.handles.first(where: { $0.keyID == m.keyID && $0.side == side }),
              let k = c.curve.keys.first(where: { $0.id == m.keyID }) else { return nil }
        let dir: Double = side == .outgoing ? 1 : -1
        let reachPts = h.segmentSeconds * GraphMath.handleReach * lane.pointsPerSecond
        guard reachPts > 0 else { return nil }
        let influence = min(max(Double(target.x - lane.x(seconds: k.seconds)) * dir / reachPts, 0.01), 1)
        var rel = max(speed(atY: target.y), 0)
        if abs(y(speed: rel) - plotBottom) <= 4 { rel = 0 }          // snaps to a full stop near the zero line
        if Self.relative(h) < 0 { rel = -rel }
        return EaseHandle(dx: influence, dy: rel * influence)
    }
}

// MARK: - Gesture reducer

/// One mouse gesture in the Graph Editor (down, drag..., up). Pure: the view feeds it points and turns the results
/// into model calls (key moves and handle edits act on the whole selection, as After Effects).
public struct GraphEditorGesture: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keys
        case handle(SummaryMember, KeySide)
        case marquee(additive: Bool)
        case none
    }

    public enum Action: Sendable, Equatable {
        /// Move the selected keys by this many seconds from where they were at mouse-down.
        case moveKeys(seconds: Double)
        /// Give every selected key this handle on `side`.
        case setHandle(EaseHandle, KeySide)
        case select(Set<SummaryMember>, marquee: CGRect?)
        case nothing
    }

    /// Keys and marquee start after this distance; handles follow the pointer from the first pixel.
    public static let dragThreshold: CGFloat = 3

    public let kind: Kind
    public let origin: CGPoint
    public let geometry: GraphEditorGeometry
    public let baseSelection: Set<SummaryMember>
    /// Selection right after mouse-down (what a key drag moves).
    public private(set) var selection: Set<SummaryMember>
    public private(set) var moved = false
    private var collapseTo: Set<SummaryMember>?
    private var handleAxis: GraphGestureState.Axis?
    private let grab: CGPoint

    public init(at p: CGPoint, shift: Bool, geometry: GraphEditorGeometry, selection: Set<SummaryMember>) {
        origin = p; self.geometry = geometry; baseSelection = selection; self.selection = selection
        var grab = p
        switch geometry.hitTest(p, selected: selection) {
        case .handle(let m, let side):
            kind = .handle(m, side)
            if let c = geometry.curve(m.property), let h = c.curve.handles.first(where: { $0.keyID == m.keyID && $0.side == side }),
               let tp = geometry.handlePoint(c, h) { grab = tp }
        case .key(let m):
            let stack = geometry.stack(of: m)
            if shift {
                if selection.contains(m) { self.selection.subtract(stack); kind = .none } else { self.selection.formUnion(stack); kind = .keys }
            } else {
                if selection.contains(m) { collapseTo = stack } else { self.selection = stack }
                kind = .keys
            }
        case .empty:
            if !shift { self.selection = [] }
            kind = .marquee(additive: shift)
        }
        self.grab = grab
    }

    /// `constrain`: Shift held, a handle drag keeps to the axis it started along.
    public mutating func drag(to p: CGPoint, constrain: Bool = false) -> Action {
        if !moved {
            let isHandle: Bool = { if case .handle = kind { return true } else { return false } }()
            guard isHandle ? p != origin : hypot(p.x - origin.x, p.y - origin.y) >= Self.dragThreshold else { return .nothing }
            moved = true
        }
        switch kind {
        case .keys:
            return .moveKeys(seconds: Double(p.x - origin.x) / max(geometry.lane.pointsPerSecond, 1e-9))
        case .handle(let m, let side):
            var dx = p.x - origin.x, dy = p.y - origin.y
            if constrain {
                if handleAxis == nil { handleAxis = abs(dx) >= abs(dy) ? .horizontal : .vertical }
                if handleAxis == .horizontal { dy = 0 } else { dx = 0 }
            }
            // The handle follows the pointer 1:1 from where it is drawn (no jump under the pointer).
            guard let h = geometry.dragHandle(m, side: side, to: CGPoint(x: grab.x + dx, y: grab.y + dy)) else { return .nothing }
            return .setHandle(h, side)
        case .marquee(let additive):
            let rect = CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y), width: abs(p.x - origin.x), height: abs(p.y - origin.y))
            let hit = geometry.members(in: rect)
            selection = additive ? baseSelection.union(hit) : hit
            return .select(selection, marquee: rect)
        case .none:
            return .nothing
        }
    }

    /// Selection after mouse-up: a plain click on an already-selected key collapses the selection to it (its stack).
    public func endSelection() -> Set<SummaryMember> {
        if !moved, let m = collapseTo { return m }
        return selection
    }
}

/// Color slot per property: Position, Scale, Rotation, Opacity, Anchor, Volume, Shutter keep fixed slots; effect
/// parameters take the next slots in list order.
public enum GraphEditorPalette {
    public static let count = 12
    static let fixedCount = 7
    public static func slots(for properties: [EffectProperty]) -> [Int] {
        let fixed: [EffectProperty: Int] = [.position: 0, .scale: 1, .rotation: 2, .opacity: 3, .anchor: 4, .volume: 5, .shutterAngle: 6]
        var next = 0
        return properties.map { p in
            if let f = fixed[p] { return f }
            defer { next += 1 }
            return fixedCount + next % (count - fixedCount)
        }
    }
}
