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

    /// Every key time through `f` (keeps ids). A track must stay in time order to evaluate, and no key is dropped:
    /// - `f` rising (a shift, a retime): order and easing stay.
    /// - `f` falling (a reverse mirrors the keys): the keys are turned around exactly, keys that land on one tick keep
    ///   their mirrored order, and every segment keeps its shape played backwards (`mirrored`).
    /// - anything else: sorted by time.
    func remapped(_ f: (Time) -> Time) -> AnimatedProperty {
        var c = self
        let keys = track.keys.map { var k = $0; k.time = f(k.time); return k }
        if keys.count < 2 || zip(keys, keys.dropFirst()).allSatisfy({ $0.time <= $1.time }) {
            c.track.keys = keys
        } else if zip(keys, keys.dropFirst()).allSatisfy({ $0.time >= $1.time }) {
            c.track.keys = Self.mirrored(keys)
        } else {
            c.track.keys = keys.sorted { $0.time < $1.time }
        }
        return c
    }

    /// Keys in falling time order turned around. A segment reads its left key's out side, its right key's in side and its
    /// left key's shape (`KeyframeTrack.segmentValue`), and after the turn its right key leads it: every key swaps its in
    /// and out sides (the ease curve rotated 180 degrees, the spatial path walked backwards, as `setSpeed` does for speed
    /// segments) and takes the shape of the key that led its segment before, played backwards (`Interpolation.mirrored`:
    /// A held up to B shows A over the span and B from B's time on, so the reverse shows B on its time and A right after
    /// it: B is a Hold Ahead). The shape of the old last key, which led nothing, goes to the new last key as it is, so a
    /// second reverse gives the original back, key for key.
    private static func mirrored(_ old: [Keyframe<V>]) -> [Keyframe<V>] {
        // Rising time order, sides swapped; `interpolation` is still the old one: key i + 1 led the segment i ... i + 1.
        var r: [Keyframe<V>] = old.reversed().map {
            var k = $0
            (k.inHandle, k.outHandle) = (k.outHandle, k.inHandle)
            (k.inTangent, k.outTangent) = (k.outTangent, k.inTangent)
            return k
        }
        let last = r[0].interpolation
        for i in r.indices.dropLast() { r[i].interpolation = r[i + 1].interpolation.mirrored }
        r[r.count - 1].interpolation = last
        return r
    }

    /// Moves every key by `delta` (keeps ids and easing).
    public func shifted(by delta: Time) -> AnimatedProperty {
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
    /// Perspective tilt about the horizontal / vertical axis through the anchor, degrees within +/-89 (`PerspectiveTilt`).
    /// 0 / 0 = the flat, untilted layer.
    public var tiltX: Double
    public var tiltY: Double

    public init(position: Vec2 = .zero, scale: Vec2 = Vec2(1, 1), rotation: Double = 0,
                opacity: Double = 1, anchor: Vec2 = .zero, tiltX: Double = 0, tiltY: Double = 0) {
        self.position = position; self.scale = scale; self.rotation = rotation
        self.opacity = opacity; self.anchor = anchor
        self.tiltX = tiltX; self.tiltY = tiltY
    }

    /// The layer is turned out of its plane.
    public var isTilted: Bool { tiltX != 0 || tiltY != 0 }

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
    /// FB-G (v40): Motion's own Shutter Angle in degrees (0 = closed, up to 360), like the Transform effect's. Blurs the clip's
    /// whole rendered motion (`Clip.motionBlur`). Only written when open or keyed.
    public var shutterAngle = AnimatedProperty(0.0)
    /// v92: Motion's Anti-flicker Filter, 0 (off) ... 1: a vertical softening of the layer that calms thin horizontal detail
    /// shimmering on interlaced displays. Written only when above 0 or keyed (`isAntiFlickerSetOrKeyed`).
    public var antiFlicker = AnimatedProperty(0.0)
    /// v84: perspective tilt (`PerspectiveTilt`), degrees. Written only when set or keyed (`isTiltSetOrKeyed`).
    public var tiltX = AnimatedProperty(0.0)
    public var tiltY = AnimatedProperty(0.0)
    /// Pre-v9 Rounded Corners radius, read only so `Clip` can migrate it into an explicit effect. Never written.
    var legacyCornerRadius: AnimatedProperty<Double>?

    public init() {}

    private enum CodingKeys: String, CodingKey { case position, scale, rotation, opacity, anchor, volume, shutterAngle, cornerRadius, tiltX, tiltY, antiFlicker }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(position, forKey: .position); try c.encode(scale, forKey: .scale)
        try c.encode(rotation, forKey: .rotation); try c.encode(opacity, forKey: .opacity)
        try c.encode(anchor, forKey: .anchor); try c.encode(volume, forKey: .volume)
        if isShutterOpenOrKeyed { try c.encode(shutterAngle, forKey: .shutterAngle) }
        if isAntiFlickerSetOrKeyed { try c.encode(antiFlicker, forKey: .antiFlicker) }
        if isTiltSetOrKeyed {
            try c.encode(tiltX, forKey: .tiltX); try c.encode(tiltY, forKey: .tiltY)
            (e.userInfo[TiltSeen.key] as? TiltSeen)?.mark()   // v84 gate (`ProjectFile.encode`)
        }
    }

    /// Anti-flicker is above 0 or keyed: the file then needs v92.
    public var isAntiFlickerSetOrKeyed: Bool { antiFlicker.value != 0 || antiFlicker.isAnimated }

    /// The filter strength at a clip-local time, clamped to 0...1.
    public func antiFlickerStrength(atLocal t: Time) -> Double { min(max(antiFlicker.value(atLocal: t), 0), 1) }

    /// A tilt is set away from 0 or keyed: the file then needs v84.
    public var isTiltSetOrKeyed: Bool {
        tiltX.value != 0 || tiltX.isAnimated || tiltY.value != 0 || tiltY.isAnimated
    }

    /// Motion's Shutter Angle is open at some point (or keyed): the file then needs v40.
    public var isShutterOpenOrKeyed: Bool { shutterAngle.value != 0 || shutterAngle.isAnimated }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        position = try c.decodeIfPresent(AnimatedProperty<Vec2>.self, forKey: .position) ?? position
        scale = try c.decodeIfPresent(AnimatedProperty<Vec2>.self, forKey: .scale) ?? scale
        rotation = try c.decodeIfPresent(AnimatedProperty<Double>.self, forKey: .rotation) ?? rotation
        opacity = try c.decodeIfPresent(AnimatedProperty<Double>.self, forKey: .opacity) ?? opacity
        anchor = try c.decodeIfPresent(AnimatedProperty<Vec2>.self, forKey: .anchor) ?? anchor
        volume = try c.decodeIfPresent(AnimatedProperty<Double>.self, forKey: .volume) ?? volume
        shutterAngle = try c.decodeIfPresent(AnimatedProperty<Double>.self, forKey: .shutterAngle) ?? shutterAngle
        antiFlicker = try c.decodeIfPresent(AnimatedProperty<Double>.self, forKey: .antiFlicker) ?? antiFlicker
        tiltX = try c.decodeIfPresent(AnimatedProperty<Double>.self, forKey: .tiltX) ?? tiltX
        tiltY = try c.decodeIfPresent(AnimatedProperty<Double>.self, forKey: .tiltY) ?? tiltY
        legacyCornerRadius = try c.decodeIfPresent(AnimatedProperty<Double>.self, forKey: .cornerRadius)
    }

    /// Every key time through `f` (keeps ids and easing).
    func remapped(_ f: (Time) -> Time) -> ClipAnimation {
        var a = self
        a.position = position.remapped(f); a.scale = scale.remapped(f)
        a.rotation = rotation.remapped(f); a.opacity = opacity.remapped(f)
        a.anchor = anchor.remapped(f); a.volume = volume.remapped(f)
        a.shutterAngle = shutterAngle.remapped(f); a.antiFlicker = antiFlicker.remapped(f)
        a.tiltX = tiltX.remapped(f); a.tiltY = tiltY.remapped(f)
        return a
    }

    func shifted(by delta: Time) -> ClipAnimation {
        var a = self
        a.position = position.shifted(by: delta); a.scale = scale.shifted(by: delta)
        a.rotation = rotation.shifted(by: delta); a.opacity = opacity.shifted(by: delta)
        a.anchor = anchor.shifted(by: delta); a.volume = volume.shifted(by: delta)
        a.shutterAngle = shutterAngle.shifted(by: delta); a.antiFlicker = antiFlicker.shifted(by: delta)
        a.tiltX = tiltX.shifted(by: delta); a.tiltY = tiltY.shifted(by: delta)
        return a
    }
}

extension Clip {
    /// Transform at timeline time `t`, from the tracks where present, else the static values.
    /// Scale is clamped to >= 0 and opacity to 0...1; rotation and position are returned as evaluated.
    public func transform(at t: Time) -> ClipTransform {
        let l = t - start
        let s = animation.scale.value(atLocal: l)
        // fx toggle off: the section renders at its defaults (no evaluation at all), the stored values stay.
        let opacity = opacityEnabled ? min(max(animation.opacity.value(atLocal: l), 0), 1) : 1
        guard motionEnabled else { return ClipTransform(opacity: opacity) }
        return ClipTransform(position: animation.position.value(atLocal: l),
                             scale: Vec2(max(s.x, 0), max(s.y, 0)),
                             rotation: animation.rotation.value(atLocal: l),
                             opacity: opacity,
                             anchor: animation.anchor.value(atLocal: l),
                             tiltX: PerspectiveTilt.clamped(animation.tiltX.value(atLocal: l)),
                             tiltY: PerspectiveTilt.clamped(animation.tiltY.value(atLocal: l)))
    }

    /// Linear gain at timeline time `t` (volume line times Audio Gain), never negative.
    public func volume(at t: Time) -> Double {
        let v = max(animation.volume.value(atLocal: t - start), 0)
        return audioGainDB == 0 ? v : v * pow(10, audioGainDB / 20)
    }
}
