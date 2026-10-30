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
///
/// `hold` shows the key's value up to the next key. `holdAhead` (Hold Ahead) is a Hold played backwards, what a reverse
/// turns a Hold into: the key shows its own value on its own time only and the next key's value right after it, up to
/// that key. After the last key both show the key's value.
public enum Interpolation: String, Sendable, Hashable, Codable {
    case linear, hold, bezier, holdAhead

    /// A stepped segment (Hold or Hold Ahead): no movement, speed 0, no ease handles.
    public var isHold: Bool { self == .hold || self == .holdAhead }

    /// The same step as an ease shape: Hold Ahead belongs to a key a reverse left behind, a curve only knows Hold.
    var asEase: Interpolation { self == .holdAhead ? .hold : self }

    /// The shape that plays this one backwards: Hold and Hold Ahead swap, curves stay (their handles are swapped).
    var mirrored: Interpolation {
        switch self {
        case .hold: .holdAhead
        case .holdAhead: .hold
        case .linear, .bezier: self
        }
    }
}

/// Bezier handle in normalized segment space. `dx` in 0...1 (time influence), `dy` free (overshoot allowed).
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

    /// Encoder `userInfo` flag: write keys compactly. Only the project file sets it (ProjectFile v36 gates it): presets,
    /// templates and other payloads an older build may read keep every field.
    public static var compactCodingKey: CodingUserInfoKey { CodingUserInfoKey(rawValue: "sq.compactKeyframes")! }

    // Compact coding (project file v36): fields at their default (linear, straight handles, zero tangents) are left out
    // and read back as the default, so long generated tracks (Stabilizer) stay small. Decoding always accepts both forms.
    private enum CodingKeys: String, CodingKey {
        case id, time, value, interpolation, inHandle, outHandle, inTangent, outTangent
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        time = try c.decode(Time.self, forKey: .time)
        value = try c.decode(V.self, forKey: .value)
        interpolation = try c.decodeIfPresent(Interpolation.self, forKey: .interpolation) ?? .linear
        inHandle = try c.decodeIfPresent(EaseHandle.self, forKey: .inHandle) ?? .linear
        outHandle = try c.decodeIfPresent(EaseHandle.self, forKey: .outHandle) ?? .linear
        inTangent = try c.decodeIfPresent(Vec2.self, forKey: .inTangent) ?? .zero
        outTangent = try c.decodeIfPresent(Vec2.self, forKey: .outTangent) ?? .zero
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(time, forKey: .time)
        try c.encode(value, forKey: .value)
        let full = encoder.userInfo[Self.compactCodingKey] as? Bool != true
        if interpolation == .holdAhead { (encoder.userInfo[HoldAheadSeen.key] as? HoldAheadSeen)?.mark() }
        if full || interpolation != .linear { try c.encode(interpolation, forKey: .interpolation) }
        if full || inHandle != .linear { try c.encode(inHandle, forKey: .inHandle) }
        if full || outHandle != .linear { try c.encode(outHandle, forKey: .outHandle) }
        if full || inTangent != .zero { try c.encode(inTangent, forKey: .inTangent) }
        if full || outTangent != .zero { try c.encode(outTangent, forKey: .outTangent) }
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

    /// Eased progress for normalized time `t` on a bezier segment.
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
        // Most tracks are static (no or one key): nothing to sort or dedupe. The generic zip + Set check below costs
        // metadata lookups that dominated the prproj map (about a third of PRMapper.map).
        if keys.count < 2 { self.keys = keys; return }
        // Fast path (long generated tracks such as the Stabilizer's, and decoding them): already in strictly increasing
        // time with unique ids gives the same result as inserting one by one, without the quadratic cost.
        if zip(keys, keys.dropFirst()).allSatisfy({ $0.time < $1.time }), Set(keys.map(\.id)).count == keys.count {
            self.keys = keys
            return
        }
        self.keys = []
        for k in keys { insert(k) }
    }

    private enum CodingKeys: String, CodingKey { case keys }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keys: try c.decode([Keyframe<V>].self, forKey: .keys))
        foldLegacyHoldHelpers()   // data written before v77 (ProjectFile+V77.swift)
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
        guard let i = index(of: id) else { return }
        keys[i].value = value
    }

    /// Mutates a key in place; its time cannot be changed (use `move`).
    public mutating func update(_ id: UUID, _ body: (inout Keyframe<V>) -> Void) {
        guard let i = index(of: id) else { return }
        let t = keys[i].time, kid = keys[i].id
        body(&keys[i])
        keys[i].time = t; keys[i].id = kid
    }

    /// Edits the keys as a list (change, move, add, drop); the result is put in time order (later wins on one time).
    @discardableResult
    public mutating func editKeys<R>(_ body: (inout [Keyframe<V>]) -> R) -> R {
        var own = keys
        let r = body(&own)
        keys = KeyframeTrack(keys: own).keys
        return r
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

    /// Value of one segment at normalized time `tn` in 0...1.
    static func segmentValue(_ a: Keyframe<V>, _ b: Keyframe<V>, _ tn: Double) -> V {
        // Each key owns its handles: the curve uses a's out side and b's in side, whatever a's shape.
        // Hold on the left key still wins; Hold Ahead shows the right key from just after the left one.
        if a.interpolation == .hold { return a.value }
        if a.interpolation == .holdAhead { return tn > 0 ? b.value : a.value }
        if a.outHandle == .linear && b.inHandle == .linear { return V.interpolate(from: a, to: b, progress: tn) }
        let p = KeyframeMath.bezierProgress(tn, out: a.outHandle, in: b.inHandle)
        return V.interpolate(from: a, to: b, progress: p)
    }

    /// Index `i` of the segment holding `t` (`keys[i].time <= t < keys[i + 1].time`); nil before the first key, from
    /// the last key on, or with fewer than two keys. Binary search, no allocation.
    func segmentIndex(at t: Time) -> Int? {
        guard keys.count >= 2, t >= keys[0].time, t < keys[keys.count - 1].time else { return nil }
        var lo = 0, hi = keys.count - 1
        while hi - lo > 1 {
            let m = (lo + hi) / 2
            if keys[m].time <= t { lo = m } else { hi = m }
        }
        return lo
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
