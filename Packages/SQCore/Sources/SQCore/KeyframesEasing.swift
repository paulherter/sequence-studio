import Foundation

public enum EaseSide: Sendable, Hashable, Codable {
    case both, `in`, out
}

/// A reusable easing: outgoing shape plus both handles. Never a Hold Ahead (stored as Hold): that is a key's own
/// property, and a curve reaches places the project version gate does not see (text payloads, the curve library).
public struct EasingCurve: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var interpolation: Interpolation { didSet { interpolation = interpolation.asEase } }
    public var outHandle: EaseHandle
    public var inHandle: EaseHandle

    public init(id: UUID = UUID(), name: String, interpolation: Interpolation, outHandle: EaseHandle, inHandle: EaseHandle) {
        self.id = id; self.name = name; self.interpolation = interpolation.asEase
        self.outHandle = outHandle; self.inHandle = inHandle
    }

    private enum CodingKeys: String, CodingKey { case id, name, interpolation, outHandle, inHandle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  interpolation: try c.decode(Interpolation.self, forKey: .interpolation),
                  outHandle: try c.decode(EaseHandle.self, forKey: .outHandle), inHandle: try c.decode(EaseHandle.self, forKey: .inHandle))
    }

    /// Curve taken from a key's own shape and handles.
    public init<V: KeyframeValue>(from key: Keyframe<V>, name: String) {
        self.init(name: name, interpolation: key.interpolation, outHandle: key.outHandle, inHandle: key.inHandle)
    }

    /// Applies to one key. `.in` touches only the in-handle, `.out` the shape and out-handle.
    public func apply<V: KeyframeValue>(to key: inout Keyframe<V>, side: EaseSide = .both) {
        if side != .in {
            if !(interpolation == .hold && key.interpolation.isHold) { key.interpolation = interpolation }   // a Hold Ahead stays one
            key.outHandle = outHandle
        }
        if side != .out { key.inHandle = inHandle }
    }

    static func builtIn(_ n: Int, _ name: String, _ i: Interpolation, out: EaseHandle, in h: EaseHandle) -> EasingCurve {
        EasingCurve(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                    name: name, interpolation: i, outHandle: out, inHandle: h)
    }

    public static let linear = builtIn(1, "Steady", .linear, out: .linear, in: .linear)
    public static let hold = builtIn(2, "Hold", .hold, out: .linear, in: .linear)
    public static let easeInOut = builtIn(3, "Ease-in-out 33%", .bezier, out: EaseHandle(dx: 1.0 / 3, dy: 0), in: EaseHandle(dx: 1.0 / 3, dy: 0))
    public static let easeIn = builtIn(4, "Ease-in 33%", .bezier, out: .linear, in: EaseHandle(dx: 1.0 / 3, dy: 0))
    public static let easeOut = builtIn(5, "Ease-out 33%", .bezier, out: EaseHandle(dx: 1.0 / 3, dy: 0), in: .linear)
    public static let fastStart = builtIn(6, "Fast start", .bezier, out: EaseHandle(dx: 0.1, dy: 0.6), in: EaseHandle(dx: 0.6, dy: 0))
    public static let fastEnd = builtIn(7, "Fast end", .bezier, out: EaseHandle(dx: 0.6, dy: 0), in: EaseHandle(dx: 0.1, dy: 0.6))

    public static let builtIns: [EasingCurve] = [linear, hold, easeInOut, easeIn, easeOut, fastStart, fastEnd,
                                               premiereDefault, easeOut100, easeIn100, softLanding]
}

/// Built-in curves plus the user's saved ones.
public struct EasingLibrary: Sendable, Hashable, Codable {
    public private(set) var userCurves: [EasingCurve] = []
    public init() {}
    public var all: [EasingCurve] { EasingCurve.builtIns + userCurves }

    public mutating func add(_ curve: EasingCurve) { userCurves.append(curve) }

    /// "Save curve" from a key. Returns the new preset's id.
    @discardableResult
    public mutating func saveCurve<V: KeyframeValue>(from key: Keyframe<V>, name: String) -> UUID {
        let c = EasingCurve(from: key, name: name)
        userCurves.append(c)
        return c.id
    }

    public mutating func rename(_ id: UUID, to name: String) {
        if let i = userCurves.firstIndex(where: { $0.id == id }) { userCurves[i].name = name }
    }

    /// Built-ins cannot be removed.
    public mutating func remove(_ id: UUID) { userCurves.removeAll { $0.id == id } }
}

extension KeyframeTrack {
    /// Applies the curve to the given keys only (ids not in the track are ignored). Unselected keys are
    /// never modified: a segment uses the left key's out side and the right key's in side.
    public mutating func apply(_ curve: EasingCurve, to ids: Set<UUID>, side: EaseSide = .both) {
        for id in ids { update(id) { curve.apply(to: &$0, side: side) } }
    }

    /// If all given keys are hold, they leave hold; otherwise all become hold (`kinds`: see `setHold`).
    public mutating func toggleHold(_ ids: Set<UUID>, restoring kinds: [UUID: Interpolation] = [:]) {
        let sel = keys.filter { ids.contains($0.id) }
        guard !sel.isEmpty else { return }
        setHold(ids, !sel.allSatisfy(\.interpolation.isHold), restoring: kinds)
    }

    /// Hold only changes the interpolation; the bezier handles stay stored. Leaving hold restores
    /// bezier when the segment's handles (own out, next key's in) are non-default, else linear.
    /// A Hold Ahead is a hold already and stays what it is. A key that leaves hold does not store which of the two it
    /// was: the caller that wants it back passes it in `kinds` (key id to `.hold` or `.holdAhead`, what the key was
    /// before it left; kept by the caller for the session, nothing is stored). A key without an entry becomes a Hold.
    public mutating func setHold(_ ids: Set<UUID>, _ hold: Bool, restoring kinds: [UUID: Interpolation] = [:]) {
        for i in keys.indices where ids.contains(keys[i].id) {
            if hold {
                if !keys[i].interpolation.isHold { keys[i].interpolation = kinds[keys[i].id] == .holdAhead ? .holdAhead : .hold }
            } else if keys[i].interpolation.isHold {
                let next = i + 1 < keys.count ? keys[i + 1].inHandle : EaseHandle.linear
                keys[i].interpolation = (keys[i].outHandle != .linear || next != .linear) ? .bezier : .linear
            }
        }
    }

    /// The menu entries Hold and Hold Ahead: the given keys become exactly `kind` (a Hold Ahead becomes a Hold and the
    /// other way round; the handles stay stored). Any other kind is ignored.
    public mutating func setHoldKind(_ kind: Interpolation, _ ids: Set<UUID>) {
        guard kind.isHold else { return }
        for i in keys.indices where ids.contains(keys[i].id) { keys[i].interpolation = kind }
    }
}
