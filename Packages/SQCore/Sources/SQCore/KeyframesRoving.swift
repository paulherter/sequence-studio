import Foundation

// MARK: - Roving keys, time scale and velocity numbers

extension KeyframeTrack where V == Vec2 {
    /// Roving keys: the selected keys between two fixed keys (the first and last key always stay fixed) are moved in
    /// time so the position travels at one steady speed along the path from one fixed key to the next. Values and
    /// tangents stay; only times change. Returns false when no interior selected key moved.
    @discardableResult
    public mutating func rove(_ ids: Set<UUID>) -> Bool {
        guard keys.count >= 3 else { return false }
        var moved = false
        var anchor = 0
        for i in 1..<keys.count {
            let isFixed = i == keys.count - 1 || !ids.contains(keys[i].id)
            guard isFixed else { continue }
            if i - anchor > 1 { moved = rove(from: anchor, to: i) || moved }
            anchor = i
        }
        return moved
    }

    private mutating func rove(from a: Int, to b: Int) -> Bool {
        var cumulative: [Double] = [0]
        for i in a..<b {
            let p = SpatialPath(p0: keys[i].value, p1: keys[i].value + keys[i].outTangent,
                                p2: keys[i + 1].value + keys[i + 1].inTangent, p3: keys[i + 1].value)
            cumulative.append(cumulative[cumulative.count - 1] + p.length)
        }
        guard let total = cumulative.last, total > 1e-9 else { return false }
        let t0 = keys[a].time, span = keys[b].time - t0
        var changed = false
        for i in (a + 1)..<b {
            let n = Int64((cumulative[i - a] / total * 1_000_000).rounded())
            let t = t0 + Time.scaled(span, by: n, over: 1_000_000)
            if t != keys[i].time { keys[i].time = t; changed = true }
        }
        return changed
    }
}

extension KeyframeTrack {
    /// Scales the time distance of the selected keys from `pivot` by `num / den` (> 0), as the Graph Editor's time
    /// scale. A scaled key landing on an unselected key replaces it. False when nothing moved.
    @discardableResult
    public mutating func scaleTimes(_ ids: Set<UUID>, by num: Int64, over den: Int64, about pivot: Time) -> Bool {
        guard num > 0, den > 0, num != den, keys.contains(where: { ids.contains($0.id) }) else { return false }
        editKeys { list in
            for i in list.indices where ids.contains(list[i].id) {
                list[i].time = pivot + Time.scaled(list[i].time - pivot, by: num, over: den)
            }
        }
        return true
    }
}

/// The numbers of the Keyframe Velocity dialog: speed (units per second) and influence (0...1 of the segment's reach)
/// of one handle, against the segment's average speed. Pure conversion to and from the stored `EaseHandle`.
public enum KeyVelocity {
    public static let minInfluence = 0.01

    public static func numbers(of h: EaseHandle, averageSpeed: Double) -> (speed: Double, influence: Double) {
        let influence = min(max(h.dx, minInfluence), 1)
        return (h.dy / influence * averageSpeed, influence)
    }

    /// nil when the segment has no average speed to scale against (a Hold, or two equal values).
    public static func handle(speed: Double, influence: Double, averageSpeed: Double) -> EaseHandle? {
        guard averageSpeed.isFinite, abs(averageSpeed) > 1e-12, speed.isFinite, influence.isFinite else { return nil }
        let inf = min(max(influence, minInfluence), 1)
        return EaseHandle(dx: inf, dy: speed / averageSpeed * inf)
    }
}

extension PropertyTrack {
    /// `KeyframeTrack.scaleTimes` for any value type.
    @discardableResult
    public mutating func scaleTimes(_ ids: Set<UUID>, by num: Int64, over den: Int64, about pivot: Time) -> Bool {
        switch self {
        case .scalar(var t): let r = t.scaleTimes(ids, by: num, over: den, about: pivot); self = .scalar(t); return r
        case .vector(var t): let r = t.scaleTimes(ids, by: num, over: den, about: pivot); self = .vector(t); return r
        case .color(var t): let r = t.scaleTimes(ids, by: num, over: den, about: pivot); self = .color(t); return r
        case .path(var t): let r = t.scaleTimes(ids, by: num, over: den, about: pivot); self = .path(t); return r
        }
    }
}
