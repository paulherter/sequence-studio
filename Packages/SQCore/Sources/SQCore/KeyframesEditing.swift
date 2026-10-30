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

    /// Moves the keys by exactly `delta` and re-sorts. The caller keeps them off the time of a non-selected key
    /// (`KeyframeSummary.move`); if one lands there anyway, the moved key wins.
    public mutating func moveKeys(_ ids: Set<UUID>, by delta: Time) {
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
    /// Effect color parameter (v24).
    case color(KeyframeTrack<EffectColor>)
    /// A mask's Path (whole shape per key). Moves, eases, holds, copies like the others; it has no value or speed graph.
    case path(KeyframeTrack<MaskPath>)

    public var keyIDs: [UUID] {
        switch self {
        case .scalar(let t): t.keys.map(\.id)
        case .vector(let t): t.keys.map(\.id)
        case .color(let t): t.keys.map(\.id)
        case .path(let t): t.keys.map(\.id)
        }
    }
    /// The keys a lane shows and navigation steps through.
    public var times: [(id: UUID, time: Time)] {
        switch self {
        case .scalar(let t): t.keys.map { ($0.id, $0.time) }
        case .vector(let t): t.keys.map { ($0.id, $0.time) }
        case .color(let t): t.keys.map { ($0.id, $0.time) }
        case .path(let t): t.keys.map { ($0.id, $0.time) }
        }
    }

    /// Interpolation of one key (nil when the id is not on this track).
    public func interpolation(of id: UUID) -> Interpolation? {
        switch self {
        case .scalar(let t): t.key(id: id)?.interpolation
        case .vector(let t): t.key(id: id)?.interpolation
        case .color(let t): t.key(id: id)?.interpolation
        case .path(let t): t.key(id: id)?.interpolation
        }
    }

    public mutating func apply(_ curve: EasingCurve, to ids: Set<UUID>, side: EaseSide = .both) {
        switch self {
        case .scalar(var t): t.apply(curve, to: ids, side: side); self = .scalar(t)
        case .vector(var t): t.apply(curve, to: ids, side: side); self = .vector(t)
        case .color(var t): t.apply(curve, to: ids, side: side); self = .color(t)
        case .path(var t): t.apply(curve, to: ids, side: side); self = .path(t)
        }
    }

    public mutating func toggleHold(_ ids: Set<UUID>) {
        switch self {
        case .scalar(var t): t.toggleHold(ids); self = .scalar(t)
        case .vector(var t): t.toggleHold(ids); self = .vector(t)
        case .color(var t): t.toggleHold(ids); self = .color(t)
        case .path(var t): t.toggleHold(ids); self = .path(t)
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

    mutating func moveKeys(_ ids: Set<UUID>, by d: Time) {
        switch self {
        case .scalar(var t): t.moveKeys(ids, by: d); self = .scalar(t)
        case .vector(var t): t.moveKeys(ids, by: d); self = .vector(t)
        case .color(var t): t.moveKeys(ids, by: d); self = .color(t)
        case .path(var t): t.moveKeys(ids, by: d); self = .path(t)
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
    public init(time: Time, members: Set<SummaryMember>) { self.time = time; self.members = members }
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

    /// Moves the members in time by `delta` (clamped to `limits`, the allowed delta range). Keys pass their non-selected
    /// neighbors (the track re-sorts, nobody is replaced). Landing exactly on the time of another key would merge two
    /// keys, so the move snaps one `frame` further in the direction of travel instead (the other way when `limits`
    /// stop it). Returns the delta actually applied.
    @discardableResult
    public mutating func move(_ members: Set<SummaryMember>, by delta: Time, frame: Time,
                              limits: ClosedRange<Time>? = nil) -> Time {
        let sel = byProperty(members)
        guard !sel.isEmpty, delta != .zero, frame > .zero else { return .zero }
        func clamp(_ d: Time) -> Time { limits.map { min(max(d, $0.lowerBound), $0.upperBound) } ?? d }
        func allowed(_ d: Time) -> Bool { limits?.contains(d) ?? true }
        // Times of the keys that stay put, per property.
        var fixed: [PropertyID: Set<Time>] = [:]
        for (p, ids) in sel { fixed[p] = Set((tracks[p]?.times ?? []).filter { !ids.contains($0.id) }.map(\.time)) }
        func collides(_ d: Time) -> Bool {
            for (p, ids) in sel {
                guard let t = tracks[p], let stay = fixed[p], !stay.isEmpty else { continue }
                if t.times.contains(where: { ids.contains($0.id) && stay.contains($0.time + d) }) { return true }
            }
            return false
        }
        var d = clamp(delta)
        if collides(d) {
            let step = delta > .zero ? frame : .zero - frame
            func search(from start: Time, step: Time) -> Time? {
                var c = start + step
                for _ in 0 ..< 10_000 where allowed(c) {
                    if !collides(c) { return c }
                    c = c + step
                }
                return nil
            }
            guard let found = search(from: d, step: step) ?? search(from: d, step: .zero - step) else { return .zero }
            d = found
        }
        guard d != .zero else { return .zero }
        for (p, ids) in sel { tracks[p]?.moveKeys(ids, by: d) }
        return d
    }

    public mutating func apply(_ curve: EasingCurve, to members: Set<SummaryMember>, side: EaseSide = .both) {
        for (p, ids) in byProperty(members) { tracks[p]?.apply(curve, to: ids, side: side) }
    }

    /// `kinds`: which hold a key that becomes one again was before it left (`KeyframeTrack.setHold`).
    public mutating func toggleHold(_ members: Set<SummaryMember>, restoring kinds: [UUID: Interpolation] = [:]) {
        let sel = byProperty(members)
        // One decision across all properties so the group stays consistent.
        let allHold = sel.allSatisfy { p, ids in
            tracks[p]?.holdState(ids) ?? true
        }
        for (p, ids) in sel { tracks[p]?.setHold(ids, !allHold, restoring: kinds) }
    }
}

extension PropertyTrack {
    mutating func setHold(_ ids: Set<UUID>, _ hold: Bool, restoring kinds: [UUID: Interpolation] = [:]) {
        switch self {
        case .scalar(var t): t.setHold(ids, hold, restoring: kinds); self = .scalar(t)
        case .vector(var t): t.setHold(ids, hold, restoring: kinds); self = .vector(t)
        case .color(var t): t.setHold(ids, hold, restoring: kinds); self = .color(t)
        case .path(var t): t.setHold(ids, hold, restoring: kinds); self = .path(t)
        }
    }

    mutating func setHoldKind(_ kind: Interpolation, _ ids: Set<UUID>) {
        switch self {
        case .scalar(var t): t.setHoldKind(kind, ids); self = .scalar(t)
        case .vector(var t): t.setHoldKind(kind, ids); self = .vector(t)
        case .color(var t): t.setHoldKind(kind, ids); self = .color(t)
        case .path(var t): t.setHoldKind(kind, ids); self = .path(t)
        }
    }

    /// True if every given key is hold (and at least no key is non-hold).
    func holdState(_ ids: Set<UUID>) -> Bool {
        times.filter { ids.contains($0.id) }.allSatisfy { interpolation(of: $0.id)?.isHold ?? false }
    }
}
