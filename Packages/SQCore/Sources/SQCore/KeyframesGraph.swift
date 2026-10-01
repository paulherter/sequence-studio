import Foundation

public struct ValueSample<V: KeyframeValue>: Sendable, Hashable {
    /// Seconds (output only).
    public var time: Double
    public var value: V
}

public struct SpeedSample: Sendable, Hashable {
    public var time: Double
    /// Value units per second (vectors: magnitude).
    public var speed: Double
}

public struct ValueGraphSegment<V: KeyframeValue>: Sendable, Hashable {
    public var fromID: UUID
    public var toID: UUID
    public var samples: [ValueSample<V>]
}

public struct SpeedGraphSegment: Sendable, Hashable {
    public var fromID: UUID
    public var toID: UUID
    public var samples: [SpeedSample]
}

extension KeyframeTrack {
    /// One entry per segment, `samples` points each (min 2) from the left key to the right key.
    public func valueGraph(samples n: Int) -> [ValueGraphSegment<V>] {
        let n = max(n, 2)
        return zip(keys, keys.dropFirst()).map { a, b in
            let t0 = KeyframeMath.seconds(a.time), d = KeyframeMath.seconds(b.time) - t0
            let pts = (0..<n).map { i -> ValueSample<V> in
                let tn = Double(i) / Double(n - 1)
                return ValueSample(time: t0 + tn * d, value: i == n - 1 ? b.value : Self.segmentValue(a, b, tn))
            }
            return ValueGraphSegment(fromID: a.id, toID: b.id, samples: pts)
        }
    }

    /// Speed = dv/dt in value units per second (central differences on the evaluated segment).
    public func speedGraph(samples n: Int) -> [SpeedGraphSegment] {
        let n = max(n, 2)
        return zip(keys, keys.dropFirst()).map { a, b in
            let t0 = KeyframeMath.seconds(a.time), d = KeyframeMath.seconds(b.time) - t0
            let h = 1e-4
            let pts = (0..<n).map { i -> SpeedSample in
                let tn = Double(i) / Double(n - 1)
                let lo = max(0, tn - h), hi = min(1, tn + h)
                let dv = Self.segmentValue(a, b, hi) - Self.segmentValue(a, b, lo)
                return SpeedSample(time: t0 + tn * d, speed: dv.speedMagnitude / ((hi - lo) * d))
            }
            return SpeedGraphSegment(fromID: a.id, toID: b.id, samples: pts)
        }
    }
}

/// After-Effects style handle: value units per second and time influence (0...1).
public struct SpeedHandle: Sendable, Hashable, Codable {
    public var speed: Double
    public var influence: Double
    public init(speed: Double, influence: Double) { self.speed = speed; self.influence = influence }
}

extension EaseHandle {
    /// `valueDelta` = |right value - left value| (signed for scalars), `duration` = segment length.
    public func speedHandle(valueDelta: Double, duration: Time) -> SpeedHandle {
        guard dx > 0 else { return SpeedHandle(speed: 0, influence: dx) }
        let secs = KeyframeMath.seconds(duration)
        return SpeedHandle(speed: dy / dx * valueDelta / secs, influence: dx)
    }

    public init(speedHandle h: SpeedHandle, valueDelta: Double, duration: Time) {
        let secs = KeyframeMath.seconds(duration)
        let linearSpeed = valueDelta / secs
        let slope = linearSpeed == 0 ? 0 : h.speed / linearSpeed
        self.init(dx: h.influence, dy: slope * h.influence)
    }
}
