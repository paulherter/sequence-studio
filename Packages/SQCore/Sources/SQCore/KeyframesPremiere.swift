import Foundation

/// The temporal interpolation entries of Premiere's keyframe right-click menu, mapped to our model.
/// Ease In / Ease Out change one side of the key only; Easy Ease and Bezier both; Hold is the outgoing side.
/// Hold Ahead (our own entry, directly under Hold) is the mirrored hold: the next key's value from right after the key.
public enum KeyInterpolationChoice: String, Sendable, CaseIterable, Hashable {
    case linear, bezier, autoBezier, continuousBezier, easeIn, easeOut, easyEase, hold, holdAhead

    public var title: String {
        switch self {
        case .linear: EaseName.steady
        case .bezier: "Bezier"
        case .autoBezier: "Auto Bezier"
        case .continuousBezier: "Continuous Bezier"
        case .easeIn: EaseName.smoothIn
        case .easeOut: EaseName.smoothOut
        case .easyEase: EaseName.smooth
        case .hold: EaseName.hold
        case .holdAhead: EaseName.holdAhead
        }
    }

    /// Hold and Hold Ahead set the key's kind itself (`KeyframeTrack.setHoldKind`), so one can be turned into the
    /// other; nil for every other entry.
    public var holdKind: Interpolation? {
        switch self {
        case .hold: .hold
        case .holdAhead: .holdAhead
        default: nil
        }
    }

    /// Menu wording for the Temporal Interpolation submenu: the same names as the one-click list (EaseName), so one
    /// curve never reads two ways in two menus of the same right-click.
    public var fullTitle: String { title }

    public var side: EaseSide {
        switch self {
        case .easeIn: .in
        case .easeOut, .hold, .holdAhead: .out
        case .linear, .bezier, .autoBezier, .continuousBezier, .easyEase: .both
        }
    }

    /// Auto and Continuous Bezier also smooth the spatial path of Position keys.
    public var smoothsSpatialPath: Bool { self == .autoBezier || self == .continuousBezier }

    /// The curve of the entry. Hold Ahead has none of its own (a curve only knows Hold): apply the choice with
    /// `PropertyTrack.apply(_:to:)`, which writes the kind.
    public var curve: EasingCurve {
        switch self {
        case .linear: .linear
        case .bezier: .bezierHandles
        case .autoBezier: .bezierHandles          // straight speed, the path is what gets smoothed
        case .continuousBezier: .easeInOut
        case .easeIn: .easeIn
        case .easeOut: .easeOut
        case .easyEase: .easeInOut
        case .hold, .holdAhead: .hold
        }
    }
}

extension EasingCurve {
    /// Bezier handles that start on the straight line (so the motion is unchanged until the user bends them) but are
    /// not the linear default, so the key reads as a Bezier key.
    public static let bezierHandles = EasingCurve(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!, name: "Bezier", interpolation: .bezier,
        outHandle: EaseHandle(dx: 0.4, dy: 0.4), inHandle: EaseHandle(dx: 0.4, dy: 0.4))
}

extension PropertyTrack {
    /// Applies a menu choice to the given keys.
    public mutating func apply(_ choice: KeyInterpolationChoice, to ids: Set<UUID>) {
        if let kind = choice.holdKind { setHoldKind(kind, ids); return }
        apply(choice.curve, to: ids, side: choice.side)
        if choice.smoothsSpatialPath, case .vector(var t) = self { t.smoothTangents(ids); self = .vector(t) }
    }

    /// Copies of the given keys with fresh ids (same time), for Option-drag duplicates.
    mutating func insertDuplicates(of ids: Set<UUID>, original: PropertyTrack) {
        switch (self, original) {
        case (.scalar(var t), .scalar(let o)): t.insertDuplicates(of: ids, original: o); self = .scalar(t)
        case (.vector(var t), .vector(let o)): t.insertDuplicates(of: ids, original: o); self = .vector(t)
        case (.color(var t), .color(let o)): t.insertDuplicates(of: ids, original: o); self = .color(t)
        case (.path(var t), .path(let o)): t.insertDuplicates(of: ids, original: o); self = .path(t)
        default: break
        }
    }
}

extension KeyframeTrack {
    /// Copies of `original`'s keys with these ids, under fresh ids on their old times (none where a key sits now).
    mutating func insertDuplicates(of ids: Set<UUID>, original o: KeyframeTrack) {
        let taken = Set(keys.map(\.time))
        for k in o.keys where ids.contains(k.id) && !taken.contains(k.time) {
            var c = k
            c.id = UUID()
            insert(c)
        }
    }
}

extension KeyframeSummary {
    /// Option-drag: like `move`, but a copy of every moved key stays at its original time (unless a key lands there).
    /// The originals keep their ids (so the selection follows them). Returns the delta applied.
    @discardableResult
    public mutating func moveDuplicating(_ members: Set<SummaryMember>, by delta: Time, frame: Time,
                                         limits: ClosedRange<Time>? = nil) -> Time {
        let before = tracks
        let applied = move(members, by: delta, frame: frame, limits: limits)
        guard applied != .zero else { return applied }
        var byProperty: [PropertyID: Set<UUID>] = [:]
        for m in members { byProperty[m.property, default: []].insert(m.keyID) }
        for (p, ids) in byProperty {
            guard let orig = before[p] else { continue }
            tracks[p]?.insertDuplicates(of: ids, original: orig)
        }
        return applied
    }
}

extension KeyframeClipboard {
    /// A clipboard holding exactly one property can be pasted onto another property of the same value type
    /// (Premiere pastes onto the selected property). nil when it holds several, or the types differ.
    public func retargeted(to property: PropertyID, isVector: Bool, isColor: Bool = false, isPath: Bool = false) -> KeyframeClipboard? {
        guard tracks.count == 1, let t = tracks.values.first else { return nil }
        switch (t, isVector && !isPath, isColor && !isPath, isPath) {
        case (.scalar, false, false, false), (.vector, true, false, false), (.color, false, true, false), (.path, _, _, true):
            return KeyframeClipboard(tracks: [property: t])
        default: return nil
        }
    }

    public var keyCount: Int {
        tracks.values.reduce(0) { n, t in
            switch t { case .scalar(let k): n + k.count; case .vector(let k): n + k.count; case .color(let k): n + k.count; case .path(let k): n + k.count }
        }
    }

    public var propertyIDs: Set<PropertyID> { Set(tracks.keys) }
}

// MARK: - Smooth spatial paths (Auto / Continuous Bezier, KEY-04 / KEY-17)

extension KeyframeTrack where V == Vec2 {
    /// Sets Catmull-Rom style tangents on the given keys so the path runs through them smoothly: both tangents point
    /// along the line from the previous to the next key, a third of the neighbor distance long. First and last key
    /// keep a zero tangent on their outer side (the path leaves / arrives straight).
    public mutating func smoothTangents(_ ids: Set<UUID>) {
        editKeys { keys in
            for i in keys.indices where ids.contains(keys[i].id) { Self.smoothTangent(&keys, at: i) }
        }
    }

    /// Spatial Linear: the path leaves and arrives straight at the given keys.
    public mutating func straightenTangents(_ ids: Set<UUID>) {
        editKeys { keys in
            for i in keys.indices where ids.contains(keys[i].id) { keys[i].inTangent = .zero; keys[i].outTangent = .zero }
        }
    }

    private static func smoothTangent(_ keys: inout [Keyframe<Vec2>], at i: Int) {
        guard i > 0, i < keys.count - 1 else { return }
        let prev = keys[i - 1].value, here = keys[i].value, next = keys[i + 1].value
        let chord = next - prev
        let len = chord.length
        guard len > 1e-12 else { keys[i].inTangent = .zero; keys[i].outTangent = .zero; return }
        let dir = chord * (1 / len)
        keys[i].outTangent = dir * ((next - here).length / 3)
        keys[i].inTangent = dir * (-(here - prev).length / 3)
    }

    /// Inserts a new Position key that is smooth by default (Premiere): its own tangents are computed, and neighbors
    /// that still have no tangents (never hand-shaped) are re-smoothed because their surroundings changed.
    public mutating func insertSmooth(_ key: Keyframe<Vec2>) {
        insert(key)
        let shown = keys
        guard let i = shown.firstIndex(where: { $0.id == key.id }) else { return }
        var ids: Set<UUID> = [key.id]
        for j in [i - 1, i + 1] where shown.indices.contains(j) && shown[j].inTangent == .zero && shown[j].outTangent == .zero {
            ids.insert(shown[j].id)
        }
        smoothTangents(ids)
    }
}

extension KeyframeTrack {
    /// `insert`, smooth by default when this is a Position track (`smoothSpatial`).
    public mutating func insertKey(_ key: Keyframe<V>, smoothSpatial: Bool) {
        if smoothSpatial, var t = self as? KeyframeTrack<Vec2>, let k = key as? Keyframe<Vec2> {
            t.insertSmooth(k)
            self = t as! KeyframeTrack<V>
        } else {
            insert(key)
        }
    }
}

extension KeyframeSummary {
    /// Spatial Interpolation "Linear": zero spatial tangents on the selected keys of vector (Position-like) tracks.
    public mutating func smoothSpatial(_ members: Set<SummaryMember>) {
        for m in members {
            guard case .vector(var t) = tracks[m.property] else { continue }
            t.smoothTangents([m.keyID])
            tracks[m.property] = .vector(t)
        }
    }

    /// True when the selection holds a key of a vector (Position-like) track.
    public func hasVectorKey(_ members: Set<SummaryMember>) -> Bool {
        members.contains { if case .vector = tracks[$0.property] { true } else { false } }
    }

    public mutating func straightenSpatial(_ members: Set<SummaryMember>) {
        for m in members {
            guard case .vector(var t) = tracks[m.property] else { continue }
            t.straightenTangents([m.keyID])
            tracks[m.property] = .vector(t)
        }
    }
}
