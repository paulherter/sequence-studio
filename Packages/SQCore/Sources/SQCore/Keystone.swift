import Foundation

// G1 "Keystones": reusable keyframe building blocks (punch in, shake, slide in, pulse ...). A keystone is stored with
// relative key times (0 ... `duration`) and normalized values, so it lands on any clip, at any length, in any sequence
// size. Applied, it becomes ordinary keyframes on the clip (Motion/Opacity, added onto the clip's own values), so it
// stays editable and nothing new goes into the project file. Library storage: SQLibrary (`PresetKind.keystone`).

/// Where an applied keystone sits on its clip (clip-local) and which properties it keyed. The UI keeps it while the
/// user drags the keystone's edges (`Clip.restretchKeystone`); it is not saved.
public struct KeystoneSpan: Sendable, Hashable {
    public var start: Time
    public var duration: Time
    public var properties: Set<Keystone.Property>
    public init(start: Time, duration: Time, properties: Set<Keystone.Property>) {
        self.start = start; self.duration = duration; self.properties = properties
    }
    public var end: Time { start + duration }
}

public struct Keystone: Sendable, Hashable, Codable, Identifiable {
    /// Version of the JSON payload (`PresetItem.payloadVersion` for `.keystone` presets).
    /// 2: a key may be a Hold Ahead. Written only for such a keystone (`writtenPayloadVersion`), so every other one stays
    /// readable by builds that know version 1; those skip a version 2 preset.
    public static let payloadVersion = 2

    /// The version to store next to `payload()`.
    public var writtenPayloadVersion: Int {
        func ahead<V>(_ t: KeyframeTrack<V>?) -> Bool { t?.keys.contains { $0.interpolation == .holdAhead } ?? false }
        return ahead(position) || ahead(scale) || ahead(rotation) || ahead(opacity) ? 2 : 1
    }

    public enum PayloadError: Error, Equatable, Sendable {
        case newerVersion(found: Int, supported: Int)
    }

    public enum Property: String, Sendable, Hashable, Codable, CaseIterable {
        case position, scale, rotation, opacity
    }

    /// Where a dropped keystone lands on the clip.
    public enum Anchor: String, Sendable, Hashable, Codable {
        /// Centered on the drop point (kept inside the clip).
        case free
        /// At the clip's first frame wherever it is dropped (an "in" animation).
        case clipStart
        /// Ending on the clip's last frame (an "out" animation).
        case clipEnd
    }

    public var id: UUID
    public var name: String
    /// Natural length; key times run 0 ... duration.
    public var duration: Time
    public var anchor: Anchor
    /// Offset as a fraction of the frame (1 = one frame width/height), added onto the clip's Position.
    public var position: KeyframeTrack<Vec2>?
    /// Factor on the clip's Scale (1 = unchanged).
    public var scale: KeyframeTrack<Vec2>?
    /// Degrees added onto the clip's Rotation.
    public var rotation: KeyframeTrack<Double>?
    /// Opacity 0 ... 1, multiplied onto the clip's own.
    public var opacity: KeyframeTrack<Double>?
    /// The keystone's own curve: when set it replaces every key's easing on apply (edited in the curve editor).
    public var easing: EasingCurve?
    /// A saved animation (`init(animation:side:...)`) that played in a loop: it loops again where it is picked. Nil
    /// (absent from the payload) is once, as for every keystone saved before. Applying a keystone to a clip ignores it.
    public var loops: Bool?

    public init(id: UUID = UUID(), name: String, duration: Time, anchor: Anchor = .free,
                position: KeyframeTrack<Vec2>? = nil, scale: KeyframeTrack<Vec2>? = nil,
                rotation: KeyframeTrack<Double>? = nil, opacity: KeyframeTrack<Double>? = nil, easing: EasingCurve? = nil) {
        self.id = id; self.name = name; self.duration = duration; self.anchor = anchor
        self.position = position; self.scale = scale; self.rotation = rotation; self.opacity = opacity
        self.easing = easing
    }

    public var properties: Set<Property> {
        var out: Set<Property> = []
        if let position, !position.isEmpty { out.insert(.position) }
        if let scale, !scale.isEmpty { out.insert(.scale) }
        if let rotation, !rotation.isEmpty { out.insert(.rotation) }
        if let opacity, !opacity.isEmpty { out.insert(.opacity) }
        return out
    }

    // MARK: Capture

    /// A keystone from the keys of `properties` on `clip`: times relative to the earliest key, values normalized against
    /// the clip's value there (Position as a fraction of `frameSize`, Scale as a factor, Rotation as an offset; Opacity
    /// stays absolute). Easing is kept. Nil when the chosen properties have fewer than two key times.
    public static func capture(from clip: Clip, properties: Set<Property>, frameSize: Vec2, name: String) -> Keystone? {
        let a = clip.animation
        var times: [Time] = []
        if properties.contains(.position) { times += a.position.track.keys.map(\.time) }
        if properties.contains(.scale) { times += a.scale.track.keys.map(\.time) }
        if properties.contains(.rotation) { times += a.rotation.track.keys.map(\.time) }
        if properties.contains(.opacity) { times += a.opacity.track.keys.map(\.time) }
        guard let origin = times.min(), let last = times.max(), last > origin else { return nil }

        func take<V>(_ p: Property, _ prop: AnimatedProperty<V>, _ f: (V, V) -> V) -> KeyframeTrack<V>? {
            guard properties.contains(p), prop.isAnimated else { return nil }
            let base = prop.value(atLocal: origin)
            return KeyframeTrack(keys: prop.track.keys.map { k in
                var n = k
                n.id = UUID(); n.time = k.time - origin; n.value = f(k.value, base)
                return n
            })
        }
        let w = frameSize.x == 0 ? 1 : frameSize.x, h = frameSize.y == 0 ? 1 : frameSize.y
        func ratio(_ v: Double, _ b: Double) -> Double { b == 0 ? v : v / b }
        var k = Keystone(name: name, duration: last - origin)
        k.position = take(.position, a.position) { v, b in Vec2((v.x - b.x) / w, (v.y - b.y) / h) }
        // Spatial tangents are in pixels: they follow the same normalization.
        if var p = k.position {
            p.keys = p.keys.map { var q = $0; q.inTangent = Vec2(q.inTangent.x / w, q.inTangent.y / h)
                                  q.outTangent = Vec2(q.outTangent.x / w, q.outTangent.y / h); return q }
            k.position = p
        }
        k.scale = take(.scale, a.scale) { v, b in Vec2(ratio(v.x, b.x), ratio(v.y, b.y)) }
        k.rotation = take(.rotation, a.rotation) { v, b in v - b }
        k.opacity = take(.opacity, a.opacity) { v, _ in v }
        return k
    }

    // MARK: Placement

    /// Where the keystone lands when dropped at clip-local `t` on a `clipDuration`-long clip (the drop ghost): its own
    /// length (at most the clip's), placed by `anchor` and kept inside the clip.
    public func placement(dropAt t: Time, clipDuration: Time) -> KeystoneSpan {
        let d = min(duration, clipDuration)
        let start: Time
        switch anchor {
        case .clipStart: start = .zero
        case .clipEnd: start = clipDuration - d
        case .free:
            let half = EffectPreset.scaled(d, by: Time(1, 1), over: Time(2, 1))
            start = min(max(t - half, .zero), clipDuration - d)
        }
        return KeystoneSpan(start: start, duration: d, properties: properties)
    }

    // MARK: Built-ins

    public static func builtInID(_ n: Int) -> UUID { UUID(uuidString: String(format: "6B657973-746F-6E65-0000-%012d", n))! }

    public var isBuiltIn: Bool { id.uuidString.hasPrefix("6B657973-746F-6E65-0000-") }

    public static func builtIn(named name: String) -> Keystone? { builtIns.first { $0.name == name } }

    public static let builtIns: [Keystone] = {
        func ms(_ v: Int64) -> Time { Time(v, 1000) }
        // Decelerating move (fast start, soft landing) and a symmetric ease.
        let decel = (out: EaseHandle(dx: 0.1, dy: 0.6), in: EaseHandle(dx: 0.6, dy: 0))
        let ease = EaseHandle(dx: 1.0 / 3, dy: 0)
        func two<V>(_ d: Time, _ a: V, _ b: V, out: EaseHandle, in h: EaseHandle) -> KeyframeTrack<V> {
            KeyframeTrack(keys: [Keyframe(time: .zero, value: a, interpolation: .bezier, outHandle: out),
                                 Keyframe(time: d, value: b, interpolation: .bezier, inHandle: h)])
        }
        func s(_ v: Double) -> Vec2 { Vec2(v, v) }
        let shake: [(Int64, Vec2)] = [(0, .zero), (60, Vec2(0.012, -0.008)), (120, Vec2(-0.014, 0.006)),
                                       (180, Vec2(0.009, 0.011)), (240, Vec2(-0.007, -0.009)), (300, Vec2(0.005, 0.004)),
                                       (360, Vec2(-0.003, -0.002)), (420, .zero)]
        return [
            Keystone(id: builtInID(1), name: "Punch In", duration: ms(400),
                     scale: two(ms(400), s(1), s(1.2), out: decel.out, in: decel.in)),
            Keystone(id: builtInID(2), name: "Punch Out", duration: ms(400),
                     scale: two(ms(400), s(1.2), s(1), out: decel.out, in: decel.in)),
            Keystone(id: builtInID(3), name: "Shake", duration: ms(420),
                     position: KeyframeTrack(keys: shake.map { Keyframe(time: ms($0.0), value: $0.1) })),
            Keystone(id: builtInID(4), name: "Pulse", duration: ms(500),
                     scale: KeyframeTrack(keys: [
                        Keyframe(time: .zero, value: s(1), interpolation: .bezier, outHandle: ease),
                        Keyframe(time: ms(250), value: s(1.08), interpolation: .bezier, inHandle: ease, outHandle: ease),
                        Keyframe(time: ms(500), value: s(1), interpolation: .bezier, inHandle: ease)])),
            Keystone(id: builtInID(5), name: "Slide In Left", duration: ms(500), anchor: .clipStart,
                     position: two(ms(500), Vec2(-1, 0), .zero, out: decel.out, in: decel.in)),
            Keystone(id: builtInID(6), name: "Slide In Right", duration: ms(500), anchor: .clipStart,
                     position: two(ms(500), Vec2(1, 0), .zero, out: decel.out, in: decel.in)),
            Keystone(id: builtInID(7), name: "Slide Out Left", duration: ms(500), anchor: .clipEnd,
                     position: two(ms(500), .zero, Vec2(-1, 0), out: decel.in, in: decel.out)),
            Keystone(id: builtInID(8), name: "Fade In", duration: ms(500), anchor: .clipStart,
                     opacity: two(ms(500), 0.0, 1.0, out: ease, in: ease)),
            Keystone(id: builtInID(9), name: "Fade Out", duration: ms(500), anchor: .clipEnd,
                     opacity: two(ms(500), 1.0, 0.0, out: ease, in: ease)),
            Keystone(id: builtInID(10), name: "Spin In", duration: ms(600), anchor: .clipStart,
                     scale: two(ms(600), s(0.6), s(1), out: decel.out, in: decel.in),
                     rotation: two(ms(600), -90.0, 0.0, out: decel.out, in: decel.in),
                     opacity: two(ms(300), 0.0, 1.0, out: ease, in: ease)),
            Keystone(id: builtInID(11), name: "Slow Push", duration: Time(3, 1),
                     scale: KeyframeTrack(keys: [Keyframe(time: .zero, value: s(1)), Keyframe(time: Time(3, 1), value: s(1.1))])),
        ]
    }()

    // MARK: Payload

    public func payload() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public init(payload: Data, version: Int) throws {
        guard version <= Self.payloadVersion else {
            throw PayloadError.newerVersion(found: version, supported: Self.payloadVersion)
        }
        self = try JSONDecoder().decode(Keystone.self, from: payload)
    }
}

// MARK: - Apply

extension Keystone {
    /// The keystone's keys placed at clip-local `start`, stretched to `duration`, denormalised for `frameSize`, with fresh
    /// ids and the keystone's own curve if it has one. Static values are the first key's.
    func preset(at start: Time, duration: Time, frameSize: Vec2, clipDuration: Time) -> EffectPreset {
        let len = self.duration
        func place<V>(_ track: KeyframeTrack<V>?, _ f: (Keyframe<V>) -> Keyframe<V>) -> AnimatedProperty<V>? {
            guard let track, let first = track.keys.first else { return nil }
            let placed = KeyframeTrack(keys: track.keys.map { k -> Keyframe<V> in
                var n = f(k)
                n.id = UUID()
                n.time = start + (len > .zero ? EffectPreset.scaled(k.time, by: duration, over: len) : k.time)
                if let easing { easing.apply(to: &n) }
                return n
            })
            return AnimatedProperty(f(first).value, track: placed)
        }
        let w = frameSize.x, h = frameSize.y
        return EffectPreset(anchor: .start, referenceDuration: clipDuration,
                            position: place(position) { k in
                                var n = k
                                n.value = Vec2(k.value.x * w, k.value.y * h)
                                n.inTangent = Vec2(k.inTangent.x * w, k.inTangent.y * h)
                                n.outTangent = Vec2(k.outTangent.x * w, k.outTangent.y * h)
                                return n
                            },
                            scale: place(scale) { $0 }, rotation: place(rotation) { $0 }, opacity: place(opacity) { $0 })
    }
}

extension Clip {
    /// Applies `keystone` as ordinary keys from clip-local `start` for `duration`, added onto the clip's own values
    /// (Position and Rotation add, Scale and Opacity multiply; see `EffectPreset.ApplyMode.relative`).
    @discardableResult
    public mutating func applyKeystone(_ keystone: Keystone, at start: Time, duration: Time, frameSize: Vec2) -> KeystoneSpan {
        applyPreset(keystone.preset(at: start, duration: duration, frameSize: frameSize, clipDuration: self.duration), mode: .relative)
        return KeystoneSpan(start: start, duration: duration, properties: keystone.properties)
    }

    /// Edge drag on an applied keystone: the keys of `span.properties` inside `span` move linearly into `new` (easing is
    /// normalized per segment, so it is kept). Keys outside `span` stay; a moved key wins at an identical time.
    /// False (nothing changes) for an empty old or new span.
    @discardableResult
    public mutating func restretchKeystone(_ span: KeystoneSpan, to new: KeystoneSpan) -> Bool {
        guard span.duration > .zero, new.duration > .zero else { return false }
        func remap<V>(_ p: inout AnimatedProperty<V>) {
            p.track.editKeys { keys in
                var outside: [Keyframe<V>] = [], moved: [Keyframe<V>] = []
                for k in keys {
                    if k.time >= span.start && k.time <= span.end {
                        var n = k
                        n.time = new.start + EffectPreset.scaled(k.time - span.start, by: new.duration, over: span.duration)
                        moved.append(n)
                    } else {
                        outside.append(k)
                    }
                }
                keys = outside + moved
            }
        }
        if span.properties.contains(.position) { remap(&animation.position) }
        if span.properties.contains(.scale) { remap(&animation.scale) }
        if span.properties.contains(.rotation) { remap(&animation.rotation) }
        if span.properties.contains(.opacity) { remap(&animation.opacity) }
        return true
    }
}

extension Timeline {
    /// Applies `keystone` to the video clip `id` (sequence frame size for Position). Throws `.clipNotFound`,
    /// `.wrongTrackKind` (audio) or `.trackLocked`; nothing changes then.
    @discardableResult
    public mutating func applyKeystone(_ keystone: Keystone, to id: Clip.ID, at start: Time, duration: Time) throws -> KeystoneSpan {
        guard let m = find(id) else { throw EditError.clipNotFound }
        guard tracks[m.track].kind == .video else { throw EditError.wrongTrackKind }
        guard !tracks[m.track].isLocked else { throw EditError.trackLocked }
        var c = m.clip
        let span = c.applyKeystone(keystone, at: start, duration: duration,
                                   frameSize: Vec2(Double(format.displayWidth), Double(format.height)))
        tracks[m.track].replace(c)
        return span
    }

    /// `Clip.restretchKeystone` on clip `id`. Throws `.clipNotFound`, `.trackLocked`, or `.emptyClip` for an empty span.
    public mutating func restretchKeystone(on id: Clip.ID, _ span: KeystoneSpan, to new: KeystoneSpan) throws {
        guard let m = find(id) else { throw EditError.clipNotFound }
        guard !tracks[m.track].isLocked else { throw EditError.trackLocked }
        var c = m.clip
        guard c.restretchKeystone(span, to: new) else { throw EditError.emptyClip }
        tracks[m.track].replace(c)
    }
}
