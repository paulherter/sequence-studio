import Foundation

// MARK: - Values

public struct Vec2: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Vec2(0, 0)
    public var length: Double { (x * x + y * y).squareRoot() }
    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, k: Double) -> Vec2 { Vec2(a.x * k, a.y * k) }
}

/// A value that can be keyframed.
public protocol KeyframeValue: Sendable, Hashable, Codable {
    static func lerp(_ a: Self, _ b: Self, _ t: Double) -> Self
    static func + (a: Self, b: Self) -> Self
    static func - (a: Self, b: Self) -> Self
    /// Speed measure of a difference: signed for scalars, length for vectors.
    var speedMagnitude: Double { get }
    /// Value between two keys at eased progress `p` (spatial for `Vec2`). `p` may leave 0...1 (overshoot).
    static func interpolate(from a: Keyframe<Self>, to b: Keyframe<Self>, progress p: Double) -> Self
}

extension KeyframeValue {
    public static func interpolate(from a: Keyframe<Self>, to b: Keyframe<Self>, progress p: Double) -> Self {
        lerp(a.value, b.value, p)
    }
}

extension Double: KeyframeValue {
    public static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    public var speedMagnitude: Double { self }
}

extension Vec2: KeyframeValue {
    public static func lerp(_ a: Vec2, _ b: Vec2, _ t: Double) -> Vec2 { a + (b - a) * t }
    public var speedMagnitude: Double { length }
    public static func interpolate(from a: Keyframe<Vec2>, to b: Keyframe<Vec2>, progress p: Double) -> Vec2 {
        if a.outTangent == .zero && b.inTangent == .zero { return lerp(a.value, b.value, p) }
        return SpatialPath(p0: a.value, p1: a.value + a.outTangent, p2: b.value + b.inTangent, p3: b.value)
            .point(atArcFraction: min(max(p, 0), 1))
    }
}

// MARK: - Keyframe

/// Shape of the outgoing segment. UI glyph: diamond / square / circle.
public enum Interpolation: String, Sendable, Hashable, Codable {
    case linear, hold, bezier
}

/// Bezier handle in normalised segment space. `dx` in 0...1 (time influence), `dy` free (overshoot allowed).
public struct EaseHandle: Sendable, Hashable, Codable {
    public var dx: Double
    public var dy: Double
    public init(dx: Double, dy: Double) { self.dx = dx; self.dy = dy }
    /// Handle of a straight segment.
    public static let linear = EaseHandle(dx: 1.0 / 3, dy: 1.0 / 3)
}

public struct Keyframe<V: KeyframeValue>: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var time: Time
    public var value: V
    public var interpolation: Interpolation
    public var inHandle: EaseHandle
    public var outHandle: EaseHandle
    /// Spatial tangents (used by `Vec2` only); zero = straight.
    public var inTangent: Vec2
    public var outTangent: Vec2

    public init(id: UUID = UUID(), time: Time, value: V, interpolation: Interpolation = .linear,
                inHandle: EaseHandle = .linear, outHandle: EaseHandle = .linear,
                inTangent: Vec2 = .zero, outTangent: Vec2 = .zero) {
        self.id = id; self.time = time; self.value = value; self.interpolation = interpolation
        self.inHandle = inHandle; self.outHandle = outHandle
        self.inTangent = inTangent; self.outTangent = outTangent
    }
}

// MARK: - Math

enum KeyframeMath {
    static func seconds(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

    /// `n / d` as Double via exact Int128 cross-multiplication. `d` must be positive.
    static func ratio(_ n: Time, _ d: Time) -> Double {
        let num = Int128(n.value) * Int128(d.timescale)
        let den = Int128(n.timescale) * Int128(d.value)
        return Double(num) / Double(den)
    }

    /// Cubic bezier (0,0) (x1,y1) (x2,y2) (1,1): x(s), y(s).
    static func bx(_ s: Double, _ x1: Double, _ x2: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * x1 + 3 * u * s * s * x2 + s * s * s
    }
    static func dbx(_ s: Double, _ x1: Double, _ x2: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * x1 + 6 * u * s * (x2 - x1) + 3 * s * s * (1 - x2)
    }

    /// Solve x(s) = t by Newton, bisection as fallback.
    static func solve(_ t: Double, _ x1: Double, _ x2: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        var s = t
        for _ in 0..<8 {
            let err = bx(s, x1, x2) - t
            if abs(err) < 1e-12 { return s }
            let d = dbx(s, x1, x2)
            if abs(d) < 1e-9 { break }
            let n = s - err / d
            if n < 0 || n > 1 { break }
            s = n
        }
        if abs(bx(s, x1, x2) - t) < 1e-10 { return s }
        var lo = 0.0, hi = 1.0
        for _ in 0..<60 {
            let m = (lo + hi) / 2
            if bx(m, x1, x2) < t { lo = m } else { hi = m }
        }
        return (lo + hi) / 2
    }

    /// Eased progress for normalised time `t` on a bezier segment.
    static func bezierProgress(_ t: Double, out: EaseHandle, in inH: EaseHandle) -> Double {
        let x1 = min(max(out.dx, 0), 1), x2 = 1 - min(max(inH.dx, 0), 1)
        let s = solve(t, x1, x2)
        return bx(s, out.dy, 1 - inH.dy)
    }
}

// MARK: - Track

/// Keys sorted by time, unique times.
public struct KeyframeTrack<V: KeyframeValue>: Sendable, Hashable, Codable {
    public internal(set) var keys: [Keyframe<V>]

    public init() { keys = [] }
    /// Sorts; on identical times the later element wins.
    public init(keys: [Keyframe<V>]) {
        self.keys = []
        for k in keys { insert(k) }
    }

    private enum CodingKeys: String, CodingKey { case keys }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keys: try c.decode([Keyframe<V>].self, forKey: .keys))
    }

    public var isEmpty: Bool { keys.isEmpty }
    public func key(id: UUID) -> Keyframe<V>? { keys.first { $0.id == id } }
    func index(of id: UUID) -> Int? { keys.firstIndex { $0.id == id } }

    /// Inserts; replaces any key (or same id) at the identical time.
    public mutating func insert(_ key: Keyframe<V>) {
        keys.removeAll { $0.id == key.id || $0.time == key.time }
        let i = keys.firstIndex { $0.time > key.time } ?? keys.count
        keys.insert(key, at: i)
    }

    public mutating func remove(_ id: UUID) { keys.removeAll { $0.id == id } }

    /// Moves a key; a non-selected key at the destination time is removed (the moved key wins).
    public mutating func move(_ id: UUID, to time: Time) {
        guard var k = key(id: id) else { return }
        k.time = time
        insert(k)
    }

    public mutating func set(_ id: UUID, value: V) {
        if let i = index(of: id) { keys[i].value = value }
    }

    /// Mutates a key in place; its time cannot be changed (use `move`).
    public mutating func update(_ id: UUID, _ body: (inout Keyframe<V>) -> Void) {
        guard let i = index(of: id) else { return }
        let t = keys[i].time, kid = keys[i].id
        body(&keys[i])
        keys[i].time = t; keys[i].id = kid
    }

    public func nextKey(of id: UUID) -> Keyframe<V>? {
        guard let i = index(of: id), i + 1 < keys.count else { return nil }
        return keys[i + 1]
    }
    public func previousKey(of id: UUID) -> Keyframe<V>? {
        guard let i = index(of: id), i > 0 else { return nil }
        return keys[i - 1]
    }
    public func nextKey(after t: Time) -> Keyframe<V>? { keys.first { $0.time > t } }
    public func previousKey(before t: Time) -> Keyframe<V>? { keys.last { $0.time < t } }

    // MARK: Evaluation

    /// Value of one segment at normalised time `tn` in 0...1.
    static func segmentValue(_ a: Keyframe<V>, _ b: Keyframe<V>, _ tn: Double) -> V {
        switch a.interpolation {
        case .hold: return a.value
        case .linear: return V.interpolate(from: a, to: b, progress: tn)
        case .bezier:
            let p = KeyframeMath.bezierProgress(tn, out: a.outHandle, in: b.inHandle)
            return V.interpolate(from: a, to: b, progress: p)
        }
    }

    /// Value at `t`; clamped before the first / after the last key. `nil` if empty.
    public func value(at t: Time) -> V? {
        guard let first = keys.first, let last = keys.last else { return nil }
        if t <= first.time { return first.value }
        if t >= last.time { return last.value }
        var lo = 0, hi = keys.count - 1      // keys[lo].time <= t < keys[hi].time
        while hi - lo > 1 {
            let m = (lo + hi) / 2
            if keys[m].time <= t { lo = m } else { hi = m }
        }
        let a = keys[lo], b = keys[hi]
        if t == a.time { return a.value }
        return Self.segmentValue(a, b, KeyframeMath.ratio(t - a.time, b.time - a.time))
    }
}
