import Foundation

// Graph Editor (After Effects style, speed graph only, DECISIONS 2026-10-03): the keyframed properties of a clip are
// overlaid in one speed graph. Units differ per property, so every curve is "directed speed" (along the direction of
// its segment: a falling opacity still reads as positive speed) and carries its own `peak`, which the view maps to the
// graph height. Handles keep the old model: an `EaseHandle` per side (influence dx, slope dy/dx relative to the
// segment's average speed), so applying one dragged handle to several keys gives them the same influence and the same
// relative speed, whatever their units.

/// Side of a key's speed handle.
public enum KeySide: Sendable, Hashable { case incoming, outgoing }

/// One property's curve in the Graph Editor.
public struct SpeedOverlayCurve: Sendable, Equatable {
    public struct Key: Sendable, Equatable {
        public var id: UUID
        public var seconds: Double
        /// Outgoing speed (arriving speed for the last key), directed; 0 on a Hold segment.
        public var speed: Double
        public var interpolation: Interpolation
    }

    public struct Handle: Sendable, Equatable {
        public var keyID: UUID
        public var side: KeySide
        /// Time influence 0...1 (`EaseHandle.dx`).
        public var influence: Double
        /// Directed speed at the key on this side, units per second.
        public var speed: Double
        /// Distance the segment covers (|delta|, or the path length of a Position segment).
        public var span: Double
        public var segmentSeconds: Double
    }

    /// Directed speed samples per segment.
    public var segments: [SpeedGraphSegment]
    public var keys: [Key]
    /// Handles of every key side that has a non-Hold segment.
    public var handles: [Handle]
    /// Largest |speed| of samples and handles; at least a tiny positive number.
    public var peak: Double

    public init(segments: [SpeedGraphSegment] = [], keys: [Key] = [], handles: [Handle] = [], peak: Double = 1e-9) {
        self.segments = segments; self.keys = keys; self.handles = handles; self.peak = peak
    }

    /// A property without motion: no keys, speed 0 everywhere (drawn as a flat line on the zero line).
    public static let still = SpeedOverlayCurve()
}

extension EaseHandle {
    /// Handle from a speed-graph position: `directedSpeed` in units per second along the segment (negative = backwards),
    /// `span` the distance the segment covers, `seconds` its length. Influence is kept inside 0.01...1.
    public init(directedSpeed: Double, influence: Double, span: Double, seconds: Double) {
        let dx = min(max(influence, 0.01), 1)
        let average = seconds > 0 ? span / seconds : 0
        let slope = average > 1e-12 ? directedSpeed / average : 0
        self.init(dx: dx, dy: slope * dx)
    }
}

extension KeyframeTrack {
    /// Speed curve for the overlay. `span` gives a segment's covered distance, `sign` its direction (+1 / -1) for
    /// signed (scalar) samples.
    func speedOverlay(samples n: Int, span: (Keyframe<V>, Keyframe<V>) -> Double,
                      sign: (Keyframe<V>, Keyframe<V>) -> Double) -> SpeedOverlayCurve {
        let raw = speedGraph(samples: n)
        var segments: [SpeedGraphSegment] = []
        var handles: [SpeedOverlayCurve.Handle] = []
        var peak = 0.0
        for (i, seg) in raw.enumerated() {
            let a = keys[i], b = keys[i + 1]
            let s = a.interpolation.isHold ? 1 : sign(a, b)
            let directed = SpeedGraphSegment(fromID: seg.fromID, toID: seg.toID,
                                             samples: seg.samples.map { SpeedSample(time: $0.time, speed: $0.speed * s) })
            segments.append(directed)
            for x in directed.samples { peak = max(peak, abs(x.speed)) }
            guard !a.interpolation.isHold else { continue }
            let secs = KeyframeMath.seconds(b.time - a.time)
            let d = span(a, b)
            func speed(_ h: EaseHandle) -> Double { h.dx > 0 && secs > 0 ? h.dy / h.dx * d / secs : 0 }
            handles.append(.init(keyID: a.id, side: .outgoing, influence: a.outHandle.dx, speed: speed(a.outHandle),
                                 span: d, segmentSeconds: secs))
            handles.append(.init(keyID: b.id, side: .incoming, influence: b.inHandle.dx, speed: speed(b.inHandle),
                                 span: d, segmentSeconds: secs))
        }
        for h in handles { peak = max(peak, abs(h.speed)) }
        let keyed = keys.enumerated().map { i, k -> SpeedOverlayCurve.Key in
            var v = 0.0
            if i < segments.count { v = segments[i].samples.first?.speed ?? 0 }
            else if i > 0, i - 1 < segments.count { v = segments[i - 1].samples.last?.speed ?? 0 }
            return .init(id: k.id, seconds: KeyframeMath.seconds(k.time), speed: v, interpolation: k.interpolation)
        }
        return SpeedOverlayCurve(segments: segments, keys: keyed, handles: handles, peak: max(peak, 1e-9))
    }

    /// Sets `handle` on `side` of the given keys (skipping sides without a segment or with a Hold segment).
    /// Linear keys become Bezier. Returns the number of keys changed.
    mutating func setHandle(_ handle: EaseHandle, side: KeySide, on ids: Set<UUID>) -> Int {
        editKeys { keys in
            var n = 0
            for i in keys.indices where ids.contains(keys[i].id) {
                switch side {
                case .outgoing:
                    guard i + 1 < keys.count, !keys[i].interpolation.isHold else { continue }
                    keys[i].outHandle = handle
                case .incoming:
                    guard i > 0, !keys[i - 1].interpolation.isHold else { continue }
                    keys[i].inHandle = handle
                }
                if keys[i].interpolation == .linear { keys[i].interpolation = .bezier }
                n += 1
            }
            return n
        }
    }
}

extension PropertyTrack {
    /// The property's curve in the Graph Editor; nil for colors (no speed to show).
    /// `hue`: the track is a hue in degrees; segments run the short way round the circle (350 -> 10 is a 20 degree
    /// step through 0), so span, direction and speed follow the picture, not the straight difference of the keys.
    public func speedOverlay(samples: Int = 48, hue: Bool = false) -> SpeedOverlayCurve? {
        switch self {
        case .scalar(let t0):
            let t = hue ? t0.hueUnwrapped() : t0
            return t.speedOverlay(samples: samples, span: { abs($1.value - $0.value) },
                                  sign: { $1.value < $0.value ? -1 : 1 })
        case .vector(let t):
            return t.speedOverlay(samples: samples, span: { a, b in
                if a.outTangent == .zero && b.inTangent == .zero { return (b.value - a.value).length }
                return SpatialPath(p0: a.value, p1: a.value + a.outTangent, p2: b.value + b.inTangent, p3: b.value).length
            }, sign: { _, _ in 1 })
        case .color, .path:
            return nil
        }
    }

    mutating func setHandle(_ handle: EaseHandle, side: KeySide, on ids: Set<UUID>) -> Int {
        switch self {
        case .scalar(var t): let n = t.setHandle(handle, side: side, on: ids); self = .scalar(t); return n
        case .vector(var t): let n = t.setHandle(handle, side: side, on: ids); self = .vector(t); return n
        case .color, .path: return 0
        }
    }
}

extension KeyframeSummary {
    /// Graph Editor handle drag on several keys at once: every member gets `handle` on `side`, i.e. the same influence
    /// and the same speed relative to its own segment. Returns the number of keys changed.
    @discardableResult
    public mutating func setHandle(_ handle: EaseHandle, side: KeySide, on members: Set<SummaryMember>) -> Int {
        var byProperty: [PropertyID: Set<UUID>] = [:]
        for m in members { byProperty[m.property, default: []].insert(m.keyID) }
        var n = 0
        for (p, ids) in byProperty { n += tracks[p]?.setHandle(handle, side: side, on: ids) ?? 0 }
        return n
    }
}
