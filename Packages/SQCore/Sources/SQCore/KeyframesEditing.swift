import Foundation

// MARK: - Relative multi-key editing (UX.md delta rule)

extension KeyframeTrack {
    /// The property now shows `v` at `t`. Reference is the selected key's value if one sits at `t`,
    /// else the interpolated value. Every selected key of this track moves by `v - reference`.
    /// Returns false (nothing changed) when no selected key belongs to this track.
    @discardableResult
    public mutating func setValue(_ v: V, at t: Time, selected: Set<UUID>) -> Bool {
        let targets = keys.filter { selected.contains($0.id) }
        guard !targets.isEmpty else { return false }
        let reference = targets.first { $0.time == t }?.value ?? value(at: t) ?? v
        let delta = v - reference
        for k in targets { set(k.id, value: k.value + delta) }
        return true
    }

    /// Latest allowed delta (same sign, magnitude <= `delta`) so selected keys do not pass non-selected neighbours.
    func clampedMoveDelta(_ ids: Set<UUID>, _ delta: Time) -> Time {
        var d = delta
        for (i, k) in keys.enumerated() where ids.contains(k.id) {
            if delta > .zero, let n = keys[(i + 1)...].first(where: { !ids.contains($0.id) }) {
                d = min(d, n.time - k.time)
            } else if delta < .zero, let p = keys[..<i].last(where: { !ids.contains($0.id) }) {
                d = max(d, p.time - k.time)
            }
        }
        return d
    }

    /// Moves the keys by exactly `delta`; non-selected keys at a landing time are removed (moved key wins).
    mutating func moveKeys(_ ids: Set<UUID>, by delta: Time) {
        let moving = keys.filter { ids.contains($0.id) }.map { k -> Keyframe<V> in var m = k; m.time = k.time + delta; return m }
        let landing = Set(moving.map(\.time))
        keys.removeAll { ids.contains($0.id) || landing.contains($0.time) }
        for m in moving { insert(m) }
    }
}

// MARK: - Properties with mixed value types

public struct PropertyID: Sendable, Hashable, Codable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }
}

/// A track of any supported value type.
public enum PropertyTrack: Sendable, Hashable, Codable {
    case scalar(KeyframeTrack<Double>)
    case vector(KeyframeTrack<Vec2>)

    public var keyIDs: [UUID] {
        switch self {
        case .scalar(let t): t.keys.map(\.id)
        case .vector(let t): t.keys.map(\.id)
        }
    }
    public var times: [(id: UUID, time: Time)] {
        switch self {
        case .scalar(let t): t.keys.map { ($0.id, $0.time) }
        case .vector(let t): t.keys.map { ($0.id, $0.time) }
        }
    }

    public mutating func apply(_ curve: EasingCurve, to ids: Set<UUID>, side: EaseSide = .both) {
        switch self {
        case .scalar(var t): t.apply(curve, to: ids, side: side); self = .scalar(t)
        case .vector(var t): t.apply(curve, to: ids, side: side); self = .vector(t)
        }
    }

    public mutating func toggleHold(_ ids: Set<UUID>) {
        switch self {
        case .scalar(var t): t.toggleHold(ids); self = .scalar(t)
        case .vector(var t): t.toggleHold(ids); self = .vector(t)
        }
    }

    @discardableResult
    public mutating func setScalar(_ v: Double, at t: Time, selected: Set<UUID>) -> Bool {
        guard case .scalar(var tr) = self else { return false }
        let ok = tr.setValue(v, at: t, selected: selected)
        self = .scalar(tr)
        return ok
    }

    @discardableResult
    public mutating func setVector(_ v: Vec2, at t: Time, selected: Set<UUID>) -> Bool {
        guard case .vector(var tr) = self else { return false }
        let ok = tr.setValue(v, at: t, selected: selected)
        self = .vector(tr)
        return ok
    }

    func clampedMoveDelta(_ ids: Set<UUID>, _ d: Time) -> Time {
        switch self {
        case .scalar(let t): t.clampedMoveDelta(ids, d)
        case .vector(let t): t.clampedMoveDelta(ids, d)
        }
    }

    mutating func moveKeys(_ ids: Set<UUID>, by d: Time) {
        switch self {
        case .scalar(var t): t.moveKeys(ids, by: d); self = .scalar(t)
        case .vector(var t): t.moveKeys(ids, by: d); self = .vector(t)
        }
    }
}

// MARK: - Summary keyframes

public struct SummaryMember: Sendable, Hashable, Codable {
    public var property: PropertyID
    public var keyID: UUID
    public init(property: PropertyID, keyID: UUID) { self.property = property; self.keyID = keyID }
}

/// All keys of several properties sharing one time.
public struct SummaryKey: Sendable, Hashable {
    public var time: Time
    public var members: Set<SummaryMember>
}

/// Collapsed-row view over the tracks of a group or effect.
public struct KeyframeSummary: Sendable, Hashable, Codable {
    public var tracks: [PropertyID: PropertyTrack]
    public init(tracks: [PropertyID: PropertyTrack]) { self.tracks = tracks }

    /// Groups by identical time, sorted; `properties` restricts to some children (nil = all).
    public func groups(of properties: Set<PropertyID>? = nil) -> [SummaryKey] {
        var byTime: [Time: Set<SummaryMember>] = [:]
        for (p, tr) in tracks where properties?.contains(p) ?? true {
            for k in tr.times { byTime[k.time, default: []].insert(SummaryMember(property: p, keyID: k.id)) }
        }
        return byTime.keys.sorted().map { SummaryKey(time: $0, members: byTime[$0]!) }
    }

    /// Selecting a summary key = all members at that time.
    public func members(at time: Time, properties: Set<PropertyID>? = nil) -> Set<SummaryMember> {
        groups(of: properties).first { $0.time == time }?.members ?? []
    }

    private func byProperty(_ members: Set<SummaryMember>) -> [PropertyID: Set<UUID>] {
        var out: [PropertyID: Set<UUID>] = [:]
        for m in members { out[m.property, default: []].insert(m.keyID) }
        return out
    }

    /// Moves the members in time, keeping order: the delta is clamped so nothing passes a non-selected
    /// neighbour (landing exactly on one replaces it). Returns the delta actually applied.
    @discardableResult
    public mutating func move(_ members: Set<SummaryMember>, by delta: Time) -> Time {
        let sel = byProperty(members)
        guard !sel.isEmpty else { return .zero }
        var d = delta
        for (p, ids) in sel { if let t = tracks[p] { d = delta > .zero ? min(d, t.clampedMoveDelta(ids, delta)) : max(d, t.clampedMoveDelta(ids, delta)) } }
        guard d != .zero else { return .zero }
        for (p, ids) in sel { tracks[p]?.moveKeys(ids, by: d) }
        return d
    }

    public mutating func apply(_ curve: EasingCurve, to members: Set<SummaryMember>, side: EaseSide = .both) {
        for (p, ids) in byProperty(members) { tracks[p]?.apply(curve, to: ids, side: side) }
    }

    public mutating func toggleHold(_ members: Set<SummaryMember>) {
        let sel = byProperty(members)
        // One decision across all properties so the group stays consistent.
        let allHold = sel.allSatisfy { p, ids in
            tracks[p]?.holdState(ids) ?? true
        }
        for (p, ids) in sel { tracks[p]?.setHold(ids, !allHold) }
    }
}

extension PropertyTrack {
    mutating func setHold(_ ids: Set<UUID>, _ hold: Bool) {
        switch self {
        case .scalar(var t): t.setHold(ids, hold); self = .scalar(t)
        case .vector(var t): t.setHold(ids, hold); self = .vector(t)
        }
    }

    /// True if every given key is hold (and at least no key is non-hold).
    func holdState(_ ids: Set<UUID>) -> Bool {
        switch self {
        case .scalar(let t): t.keys.filter { ids.contains($0.id) }.allSatisfy { $0.interpolation == .hold }
        case .vector(let t): t.keys.filter { ids.contains($0.id) }.allSatisfy { $0.interpolation == .hold }
        }
    }
}
