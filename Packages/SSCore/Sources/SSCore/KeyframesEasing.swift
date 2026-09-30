import Foundation

public enum EaseSide: Sendable, Hashable, Codable {
    case both, `in`, out
}

/// A reusable easing: outgoing shape plus both handles.
public struct EasingCurve: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var interpolation: Interpolation
    public var outHandle: EaseHandle
    public var inHandle: EaseHandle

    public init(id: UUID = UUID(), name: String, interpolation: Interpolation, outHandle: EaseHandle, inHandle: EaseHandle) {
        self.id = id; self.name = name; self.interpolation = interpolation
        self.outHandle = outHandle; self.inHandle = inHandle
    }

    /// Curve taken from a key's own shape and handles.
    public init<V: KeyframeValue>(from key: Keyframe<V>, name: String) {
        self.init(name: name, interpolation: key.interpolation, outHandle: key.outHandle, inHandle: key.inHandle)
    }

    /// Applies to one key. `.in` touches only the in-handle, `.out` the shape and out-handle.
    public func apply<V: KeyframeValue>(to key: inout Keyframe<V>, side: EaseSide = .both) {
        if side != .in { key.interpolation = interpolation; key.outHandle = outHandle }
        if side != .out { key.inHandle = inHandle }
    }

    private static func builtIn(_ n: Int, _ name: String, _ i: Interpolation, out: EaseHandle, in h: EaseHandle) -> EasingCurve {
        EasingCurve(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                    name: name, interpolation: i, outHandle: out, inHandle: h)
    }

    public static let linear = builtIn(1, "Linear", .linear, out: .linear, in: .linear)
    public static let hold = builtIn(2, "Hold", .hold, out: .linear, in: .linear)
    public static let easeInOut = builtIn(3, "Ease in/out", .bezier, out: EaseHandle(dx: 1.0 / 3, dy: 0), in: EaseHandle(dx: 1.0 / 3, dy: 0))
    public static let easeIn = builtIn(4, "Ease in", .bezier, out: .linear, in: EaseHandle(dx: 1.0 / 3, dy: 0))
    public static let easeOut = builtIn(5, "Ease out", .bezier, out: EaseHandle(dx: 1.0 / 3, dy: 0), in: .linear)
    public static let fastStart = builtIn(6, "Fast start", .bezier, out: EaseHandle(dx: 0.1, dy: 0.6), in: EaseHandle(dx: 0.6, dy: 0))
    public static let fastEnd = builtIn(7, "Fast end", .bezier, out: EaseHandle(dx: 0.6, dy: 0), in: EaseHandle(dx: 0.1, dy: 0.6))

    public static let builtIns: [EasingCurve] = [linear, hold, easeInOut, easeIn, easeOut, fastStart, fastEnd]
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
    /// Applies the curve to the given keys (ids not in the track are ignored).
    /// For `.in`, a linear left neighbour becomes bezier so the in-handle takes effect.
    public mutating func apply(_ curve: EasingCurve, to ids: Set<UUID>, side: EaseSide = .both) {
        for id in ids {
            guard let i = index(of: id) else { continue }
            update(id) { curve.apply(to: &$0, side: side) }
            if side == .in, curve.interpolation == .bezier, i > 0, keys[i - 1].interpolation == .linear {
                keys[i - 1].interpolation = .bezier
            }
        }
    }

    /// If all given keys are hold, they become linear; otherwise all become hold.
    public mutating func toggleHold(_ ids: Set<UUID>) {
        let sel = keys.filter { ids.contains($0.id) }
        guard !sel.isEmpty else { return }
        let target: Interpolation = sel.allSatisfy { $0.interpolation == .hold } ? .linear : .hold
        for k in sel { update(k.id) { $0.interpolation = target } }
    }
}
