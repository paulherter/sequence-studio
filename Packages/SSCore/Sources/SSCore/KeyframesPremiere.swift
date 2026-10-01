import Foundation

/// The temporal interpolation entries of Premiere's keyframe right-click menu, mapped to our model.
/// Ease In / Ease Out change one side of the key only; Easy Ease and Bezier both; Hold is the outgoing side.
public enum KeyInterpolationChoice: String, Sendable, CaseIterable, Hashable {
    case linear, bezier, easeIn, easeOut, easyEase, hold

    public var title: String {
        switch self {
        case .linear: "Linear"
        case .bezier: "Bezier"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .easyEase: "Easy Ease"
        case .hold: "Hold"
        }
    }

    public var side: EaseSide {
        switch self {
        case .easeIn: .in
        case .easeOut, .hold: .out
        case .linear, .bezier, .easyEase: .both
        }
    }

    public var curve: EasingCurve {
        switch self {
        case .linear: .linear
        case .bezier: .bezierHandles
        case .easeIn: .easeIn
        case .easeOut: .easeOut
        case .easyEase: .easeInOut
        case .hold: .hold
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
        apply(choice.curve, to: ids, side: choice.side)
    }

    /// Copies of the given keys with fresh ids (same time), for Option-drag duplicates.
    mutating func insertDuplicates(of ids: Set<UUID>, original: PropertyTrack) {
        switch (self, original) {
        case (.scalar(var t), .scalar(let o)):
            for k in o.keys where ids.contains(k.id) && t.keys.allSatisfy({ $0.time != k.time }) {
                var c = k; c.id = UUID(); t.insert(c)
            }
            self = .scalar(t)
        case (.vector(var t), .vector(let o)):
            for k in o.keys where ids.contains(k.id) && t.keys.allSatisfy({ $0.time != k.time }) {
                var c = k; c.id = UUID(); t.insert(c)
            }
            self = .vector(t)
        default: break
        }
    }
}

extension KeyframeSummary {
    /// Option-drag: like `move`, but a copy of every moved key stays at its original time (unless a key lands there).
    /// The originals keep their ids (so the selection follows them). Returns the delta applied.
    @discardableResult
    public mutating func moveDuplicating(_ members: Set<SummaryMember>, by delta: Time) -> Time {
        let before = tracks
        let applied = move(members, by: delta)
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
    public func retargeted(to property: PropertyID, isVector: Bool) -> KeyframeClipboard? {
        guard tracks.count == 1, let t = tracks.values.first else { return nil }
        switch (t, isVector) {
        case (.scalar, false), (.vector, true): return KeyframeClipboard(tracks: [property: t])
        default: return nil
        }
    }

    public var keyCount: Int {
        tracks.values.reduce(0) { n, t in
            switch t { case .scalar(let k): n + k.count; case .vector(let k): n + k.count }
        }
    }

    public var propertyIDs: Set<PropertyID> { Set(tracks.keys) }
}
