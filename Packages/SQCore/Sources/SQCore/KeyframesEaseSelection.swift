import Foundation

/// The temporal shape of one segment (left key's outgoing interpolation, its out-handle, the right key's in-handle) in
/// normalized segment space. The same shape gives the same motion on every property (no per-property speed/influence).
/// `dx` is time influence (0...1), `dy` is free so a curve may overshoot or anticipate. A Hold Ahead reads as Hold.
public struct EaseShape: Sendable, Hashable, Codable {
    public var interpolation: Interpolation { didSet { interpolation = interpolation.asEase } }
    public var out: EaseHandle
    public var `in`: EaseHandle

    public init(interpolation: Interpolation, out: EaseHandle, in inHandle: EaseHandle) {
        self.interpolation = interpolation.asEase; self.out = out; self.in = inHandle
    }

    private enum CodingKeys: String, CodingKey { case interpolation, out, `in` }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(interpolation: try c.decode(Interpolation.self, forKey: .interpolation),
                  out: try c.decode(EaseHandle.self, forKey: .out), in: try c.decode(EaseHandle.self, forKey: .in))
    }

    public static let linear = EaseShape(interpolation: .linear, out: .linear, in: .linear)
    public static let hold = EaseShape(interpolation: .hold, out: .linear, in: .linear)

    /// What the segment actually does, as the evaluator sees it (`KeyframeTrack.segmentValue`): hold ignores the handles;
    /// otherwise the handles decide whatever the left key's interpolation says (Premiere's Ease In leaves the left key
    /// linear and eases only the right key's in side). Straight handles are linear.
    public var effective: EaseShape {
        if interpolation.isHold { return .hold }
        let s = EaseShape(interpolation: .bezier, out: Self.clamped(out), in: Self.clamped(`in`))
        return s.out == .linear && s.in == .linear ? .linear : s
    }

    public func isApproximatelyEqual(to o: EaseShape, tolerance: Double = 1e-6) -> Bool {
        let a = effective, b = o.effective
        guard a.interpolation == b.interpolation else { return false }
        return [a.out.dx - b.out.dx, a.out.dy - b.out.dy, a.in.dx - b.in.dx, a.in.dy - b.in.dy].allSatisfy { abs($0) <= tolerance }
    }

    static func clamped(_ h: EaseHandle) -> EaseHandle { EaseHandle(dx: min(max(h.dx, 0), 1), dy: h.dy) }
}

/// One segment of a property track, named by its two keys. `side` is what may be written: `.both` when both keys are
/// selected, `.out` (left key's shape and out-handle) or `.in` (right key's in-handle) when only that key is selected.
public struct EaseSegment: Sendable, Hashable {
    public var property: PropertyID
    public var from: UUID
    public var to: UUID
    public var side: EaseSide
    public init(property: PropertyID, from: UUID, to: UUID, side: EaseSide = .both) {
        self.property = property; self.from = from; self.to = to; self.side = side
    }
}

/// What the selected segments share.
public enum EaseReading: Sendable, Equatable {
    case empty
    case common(EaseShape)
    /// Distinct effective shapes, in segment order.
    case mixed([EaseShape])
}

/// The segments a key selection touches across all properties: per property, every segment whose two keys are both
/// selected; a property without a selected pair uses each selected key's outgoing segment (the incoming one for the
/// last key, unless the unselected key before it is Hold: that segment cannot ease without changing that key).
/// Only selected keys are ever written. Reads "common curve or mixed" and writes one curve to all of them.
public struct EaseSelection: Sendable, Hashable {
    public let segments: [EaseSegment]

    /// `stepped`: properties that only switch from key to key (effect checkbox / choice): never eased, so skipped.
    public init(summary: KeyframeSummary, members: Set<SummaryMember>, stepped: Set<PropertyID> = []) {
        var by: [PropertyID: Set<UUID>] = [:]
        for m in members where !stepped.contains(m.property) { by[m.property, default: []].insert(m.keyID) }
        var out: [EaseSegment] = []
        for p in by.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let ids = by[p], let track = summary.tracks[p] else { continue }
            let keys = track.keyIDs
            guard keys.count >= 2 else { continue }
            let pairs = keys.indices.dropLast().filter { ids.contains(keys[$0]) && ids.contains(keys[$0 + 1]) }
            if !pairs.isEmpty {
                out += pairs.map { EaseSegment(property: p, from: keys[$0], to: keys[$0 + 1]) }
                continue
            }
            // No pair here, so no two selected keys are neighbors: every lone key has its own segment.
            for i in keys.indices where ids.contains(keys[i]) {
                if i + 1 < keys.count {
                    out.append(EaseSegment(property: p, from: keys[i], to: keys[i + 1], side: .out))
                } else if !(track.interpolation(of: keys[i - 1])?.isHold ?? false) {
                    out.append(EaseSegment(property: p, from: keys[i - 1], to: keys[i], side: .in))
                }
            }
        }
        segments = out
    }

    public var isEmpty: Bool { segments.isEmpty }

    public func reading(in summary: KeyframeSummary) -> EaseReading {
        var shapes: [EaseShape] = []
        for seg in segments {
            guard let s = summary.tracks[seg.property]?.easeShape(from: seg.from, to: seg.to)?.effective else { continue }
            if !shapes.contains(where: { $0.isApproximatelyEqual(to: s) }) { shapes.append(s) }
        }
        switch shapes.count {
        case 0: return .empty
        case 1: return .common(shapes[0])
        default: return .mixed(shapes)
        }
    }

    /// Writes `shape` to every segment. Hold only changes the interpolation (the handles stay stored, like toggleHold);
    /// linear resets both handles; bezier writes both handles (`dx` clamped to 0...1, `dy` kept). Returns segments written.
    @discardableResult
    public func apply(_ shape: EaseShape, to summary: inout KeyframeSummary) -> Int {
        var n = 0
        for seg in segments {
            guard var t = summary.tracks[seg.property], t.setEaseShape(shape, from: seg.from, to: seg.to, side: seg.side) else { continue }
            summary.tracks[seg.property] = t
            n += 1
        }
        return n
    }
}

extension EaseSelection {
    /// Hold or Hold Ahead on the left key of every segment that may write it (not a segment selected by its right key
    /// only: a hold has no in side). Unlike a `.hold` shape this turns a Hold Ahead into a Hold and back. Returns
    /// segments written.
    @discardableResult
    public func setHoldKind(_ kind: Interpolation, in summary: inout KeyframeSummary) -> Int {
        guard kind.isHold else { return 0 }
        var n = 0
        for seg in segments where seg.side != .in && summary.tracks[seg.property] != nil {
            summary.tracks[seg.property]?.setHoldKind(kind, [seg.from])
            n += 1
        }
        return n
    }
}

extension KeyframeSummary {
    /// The stored kind of a key: tells Hold and Hold Ahead apart, which an `EaseShape` does not.
    public func interpolation(of m: SummaryMember) -> Interpolation? { tracks[m.property]?.interpolation(of: m.keyID) }
}

extension KeyframeTrack {
    func easeShape(from a: UUID, to b: UUID) -> EaseShape? {
        guard let l = key(id: a), let r = key(id: b) else { return nil }
        return EaseShape(interpolation: l.interpolation, out: l.outHandle, in: r.inHandle)
    }

    /// `.out` writes only the left key (shape and out-handle), `.in` only the right key's in-handle (Hold has no in side).
    mutating func setEaseShape(_ s: EaseShape, from a: UUID, to b: UUID, side: EaseSide) -> Bool {
        guard index(of: a) != nil, index(of: b) != nil else { return false }
        if side != .in {
            update(a) {
                if !(s.interpolation == .hold && $0.interpolation.isHold) { $0.interpolation = s.interpolation }   // a Hold Ahead stays one
                switch s.interpolation {
                case .hold, .holdAhead: break
                case .linear: $0.outHandle = .linear
                case .bezier: $0.outHandle = EaseShape.clamped(s.out)
                }
            }
        }
        if side != .out {
            update(b) {
                switch s.interpolation {
                case .hold, .holdAhead: break
                case .linear: $0.inHandle = .linear
                case .bezier: $0.inHandle = EaseShape.clamped(s.in)
                }
            }
        }
        return true
    }

    func interpolation(of id: UUID) -> Interpolation? { key(id: id)?.interpolation }
}

extension PropertyTrack {
    func easeShape(from a: UUID, to b: UUID) -> EaseShape? {
        switch self {
        case .scalar(let t): t.easeShape(from: a, to: b)
        case .vector(let t): t.easeShape(from: a, to: b)
        case .color(let t): t.easeShape(from: a, to: b)
        case .path(let t): t.easeShape(from: a, to: b)
        }
    }

    mutating func setEaseShape(_ s: EaseShape, from a: UUID, to b: UUID, side: EaseSide) -> Bool {
        switch self {
        case .scalar(var t): let ok = t.setEaseShape(s, from: a, to: b, side: side); self = .scalar(t); return ok
        case .vector(var t): let ok = t.setEaseShape(s, from: a, to: b, side: side); self = .vector(t); return ok
        case .color(var t): let ok = t.setEaseShape(s, from: a, to: b, side: side); self = .color(t); return ok
        case .path(var t): let ok = t.setEaseShape(s, from: a, to: b, side: side); self = .path(t); return ok
        }
    }
}

extension EasingCurve {
    /// The curve as a segment shape (out of the left key, in of the right key).
    public var shape: EaseShape { EaseShape(interpolation: interpolation, out: outHandle, in: inHandle) }

    public init(id: UUID = UUID(), shape: EaseShape, name: String) {
        self.init(id: id, name: name, interpolation: shape.interpolation, outHandle: shape.out, inHandle: shape.in)
    }

    /// Payload format for a PresetStore `.easing` item (the item carries id and name).
    public static let presetPayloadVersion = 1

    public func presetPayload() throws -> Data { try JSONEncoder().encode(shape) }

    public init(presetPayload data: Data, name: String, id: UUID) throws {
        self.init(id: id, shape: try JSONDecoder().decode(EaseShape.self, from: data), name: name)
    }
}
