import Foundation

/// A clip property with a static fallback and optional keyframes. Keyframe times are
/// clip-local: 0 = the clip's first frame on the timeline (`Clip.start`), independent of media time.
public struct AnimatedProperty<V: KeyframeValue>: Sendable, Hashable, Codable {
    /// Used when the track has no keys.
    public var value: V
    public var track: KeyframeTrack<V>

    public init(_ value: V, track: KeyframeTrack<V> = KeyframeTrack()) { self.value = value; self.track = track }

    public var isAnimated: Bool { !track.isEmpty }

    public func value(atLocal t: Time) -> V { track.value(at: t) ?? value }

    private enum CodingKeys: String, CodingKey { case value, track }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(try c.decode(V.self, forKey: .value),
                  track: try c.decodeIfPresent(KeyframeTrack<V>.self, forKey: .track) ?? KeyframeTrack())
    }

    /// Moves every key by `delta` (keeps ids and easing).
    func shifted(by delta: Time) -> AnimatedProperty {
        var c = self
        c.track.keys = track.keys.map { var k = $0; k.time = k.time + delta; return k }
        return c
    }
}

/// Evaluated transform of a clip at one instant, already clamped for rendering.
public struct ClipTransform: Sendable, Hashable {
    /// Linked x/y.
    public var position: Vec2
    /// Linked x/y, never negative, no upper limit, never wrapped.
    public var scale: Vec2
    /// Degrees, unbounded (720 = two turns).
    public var rotation: Double
    /// 0...1.
    public var opacity: Double
    public var anchor: Vec2

    public init(position: Vec2 = .zero, scale: Vec2 = Vec2(1, 1), rotation: Double = 0,
                opacity: Double = 1, anchor: Vec2 = .zero) {
        self.position = position; self.scale = scale; self.rotation = rotation
        self.opacity = opacity; self.anchor = anchor
    }

    public static let identity = ClipTransform()
}

/// All animatable clip properties. Defaults are static identity values.
public struct ClipAnimation: Sendable, Hashable, Codable {
    public var position = AnimatedProperty(Vec2.zero)
    public var scale = AnimatedProperty(Vec2(1, 1))
    public var rotation = AnimatedProperty(0.0)
    public var opacity = AnimatedProperty(1.0)
    public var anchor = AnimatedProperty(Vec2.zero)
    /// Linear gain (1 = unity) for audio clips.
    public var volume = AnimatedProperty(1.0)

    public init() {}

    private enum CodingKeys: String, CodingKey { case position, scale, rotation, opacity, anchor, volume }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        position = try c.decodeIfPresent(AnimatedProperty<Vec2>.self, forKey: .position) ?? position
        scale = try c.decodeIfPresent(AnimatedProperty<Vec2>.self, forKey: .scale) ?? scale
        rotation = try c.decodeIfPresent(AnimatedProperty<Double>.self, forKey: .rotation) ?? rotation
        opacity = try c.decodeIfPresent(AnimatedProperty<Double>.self, forKey: .opacity) ?? opacity
        anchor = try c.decodeIfPresent(AnimatedProperty<Vec2>.self, forKey: .anchor) ?? anchor
        volume = try c.decodeIfPresent(AnimatedProperty<Double>.self, forKey: .volume) ?? volume
    }

    func shifted(by delta: Time) -> ClipAnimation {
        var a = self
        a.position = position.shifted(by: delta); a.scale = scale.shifted(by: delta)
        a.rotation = rotation.shifted(by: delta); a.opacity = opacity.shifted(by: delta)
        a.anchor = anchor.shifted(by: delta); a.volume = volume.shifted(by: delta)
        return a
    }
}

extension Clip {
    /// Transform at timeline time `t`, from the tracks where present, else the static values.
    /// Scale is clamped to >= 0 and opacity to 0...1; rotation and position are returned as evaluated.
    public func transform(at t: Time) -> ClipTransform {
        let l = t - start
        let s = animation.scale.value(atLocal: l)
        return ClipTransform(position: animation.position.value(atLocal: l),
                             scale: Vec2(max(s.x, 0), max(s.y, 0)),
                             rotation: animation.rotation.value(atLocal: l),
                             opacity: min(max(animation.opacity.value(atLocal: l), 0), 1),
                             anchor: animation.anchor.value(atLocal: l))
    }

    /// Linear gain at timeline time `t`, never negative.
    public func volume(at t: Time) -> Double { max(animation.volume.value(atLocal: t - start), 0) }
}
