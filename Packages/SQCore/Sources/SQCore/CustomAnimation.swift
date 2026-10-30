import Foundation

/// The two sides of an item's animation (`AnimationSet.animationIn` / `animationOut`).
public enum AnimationSide: String, Sendable, Hashable, Codable, CaseIterable {
    case intro, outro

    public var title: String { self == .intro ? "Intro" : "Outro" }
}

/// What a Custom animation keys per side: one Controls row each. Position is the pair "positionX" / "positionY".
public enum AnimationParam: String, Sendable, Hashable, Codable, CaseIterable {
    case position, scale, rotation, opacity

    public var title: String {
        switch self {
        case .position: "Position"
        case .scale: "Scale"
        case .rotation: "Rotation"
        case .opacity: "Opacity"
        }
    }

    /// The `AnimationTrack.property` names behind the row.
    public var trackNames: [String] {
        switch self {
        case .position: ["positionX", "positionY"]
        case .scale: ["scale"]
        case .rotation: ["rotation"]
        case .opacity: ["opacity"]
        }
    }

    /// The value where the row does nothing (`AnimationSample.rest`).
    public var rest: Double { self == .scale || self == .opacity ? 1 : 0 }

    static func rest(ofTrack name: String) -> Double { name == "scale" || name == "opacity" ? 1 : 0 }
}

/// A Custom animation is a `KeyframeTemplate` whose tracks the user keys by hand. These helpers show one side's tracks
/// in clip-local time (what the Controls lanes use) and write them back in template time.
extension AnimationSet {
    /// Length of a side that starts as Custom from nothing (10 frames at 30 fps).
    public static let customLength = Time(1, 3)

    public func template(_ side: AnimationSide) -> KeyframeTemplate? { side == .intro ? animationIn : animationOut }

    /// Clip time of the side's template time 0. The outro of a clip too short to play it still ends at the clip's end.
    public func offset(of side: AnimationSide, clipDuration: Time) -> Time {
        guard side == .outro else { return .zero }
        return outStart(clipDuration: clipDuration) ?? clipDuration - (animationOut?.duration ?? Self.customLength)
    }

    /// One track of a side with clip-local key times; without keys it rests.
    public func track(_ name: String, side: AnimationSide, clipDuration: Time) -> AnimatedProperty<Double> {
        let rest = AnimationParam.rest(ofTrack: name)
        guard let t = template(side), let i = t.tracks.firstIndex(where: { $0.property == name }) else { return AnimatedProperty(rest) }
        let offset = offset(of: side, clipDuration: clipDuration)
        let stored = t.tracks[i].track
        // A Custom intro is stored as it is shown (time 0 = clip start, ids of its own): no copy per read.
        if offset == .zero, !stored.keys.contains(where: { Self.isShared($0.id) }) { return AnimatedProperty(rest, track: stored) }
        var keys = stored.keys
        for k in keys.indices {
            keys[k].time = keys[k].time + offset
            keys[k].id = Self.stableID(keys[k].id, side: side, track: i)
        }
        return AnimatedProperty(rest, track: KeyframeTrack(keys: keys))
    }

    /// A scalar row (Scale, Rotation, Opacity) in clip-local time. Position reads its X member; use `position`.
    public func scalar(_ param: AnimationParam, side: AnimationSide, clipDuration: Time) -> AnimatedProperty<Double> {
        track(param.trackNames[0], side: side, clipDuration: clipDuration)
    }

    /// The Position row: both members as one point (`KeyframesPair.editable`).
    public func position(side: AnimationSide, clipDuration: Time) -> AnimatedProperty<Vec2> {
        KeyframesPair.editable(track("positionX", side: side, clipDuration: clipDuration),
                               track("positionY", side: side, clipDuration: clipDuration))
    }

    /// Edits a scalar row in clip-local time and writes it back (`write`).
    public mutating func edit(_ param: AnimationParam, side: AnimationSide, clipDuration: Time,
                              _ body: (inout AnimatedProperty<Double>) -> Void) {
        guard param != .position else { return }
        let name = param.trackNames[0]
        var v = track(name, side: side, clipDuration: clipDuration)
        let before = v
        body(&v)
        guard v != before else { return }       // nothing edited: the stored keys (and their ids) stay as they are
        write([name: v], side: side, clipDuration: clipDuration)
    }

    /// Edits the Position row in clip-local time; storage stays two aligned scalar tracks.
    public mutating func editPosition(side: AnimationSide, clipDuration: Time, _ body: (inout AnimatedProperty<Vec2>) -> Void) {
        var x = track("positionX", side: side, clipDuration: clipDuration)
        var y = track("positionY", side: side, clipDuration: clipDuration)
        var point = KeyframesPair.editable(x, y)
        let before = point
        body(&point)
        guard point != before else { return }   // nothing edited: no split into two tracks, no new ids
        KeyframesPair.edit(&x, &y) { $0 = point }
        write(["positionX": x, "positionY": y], side: side, clipDuration: clipDuration)
    }

    /// Stores tracks given in clip-local time. A track without keys is removed (the row rests). Then the side's length
    /// follows its keys: an intro ends at its last key; an outro starts at its first key and keeps its end, so every
    /// key stays at its clip time. A looping template keeps its period.
    public mutating func write(_ edited: [String: AnimatedProperty<Double>], side: AnimationSide, clipDuration: Time) {
        let offset = offset(of: side, clipDuration: clipDuration)
        var t = template(side) ?? KeyframeTemplate(tracks: [], duration: Self.customLength)
        for name in edited.keys.sorted() {
            guard let v = edited[name] else { continue }
            let i = t.tracks.firstIndex { $0.property == name }
            if v.track.isEmpty {
                if let i { t.tracks.remove(at: i) }
                continue
            }
            let track = AnimationTrack(property: name, track: v.shifted(by: .zero - offset).track)
            if let i { t.tracks[i] = track } else { t.tracks.append(track) }
        }
        let times = t.tracks.flatMap { $0.track.keys.map(\.time) }
        if !t.loops, let first = times.min(), let last = times.max() {
            switch side {
            case .intro:
                if last > .zero { t.duration = last }
            case .outro:
                let length = t.duration - first
                if first != .zero, length > .zero {
                    for i in t.tracks.indices {
                        t.tracks[i].track.keys = t.tracks[i].track.keys.map { var k = $0; k.time = k.time - first; return k }
                    }
                    t.duration = length
                }
            }
        }
        t.anchor = side == .intro ? .start : .end
        // Nothing keyed and no text animator: the side is Off again (nil, the same bits as never animated).
        let stored: KeyframeTemplate? = t.tracks.isEmpty && t.textAnimator == nil ? nil : t
        if side == .intro { animationIn = stored } else { animationOut = stored }
    }

    /// Built-in templates number their keys per track (`AnimationTrack.keyID`), so two tracks share ids. The lanes select
    /// keys by id: such an id is replaced by one that also carries side and track. The same key always maps to the same id.
    /// No string is built: the lanes ask per key.
    static func stableID(_ id: UUID, side: AnimationSide, track: Int) -> UUID {
        guard isShared(id) else { return id }
        var u = id.uuid
        u.7 = side == .intro ? 1 : 2
        u.9 = UInt8(truncatingIfNeeded: track + 1)
        return UUID(uuid: u)
    }

    /// An id numbered per track ("00000000-0000-0000-0000-…"): several tracks of a preset carry it.
    static func isShared(_ id: UUID) -> Bool {
        let u = id.uuid
        return (u.0 | u.1 | u.2 | u.3 | u.4 | u.5 | u.6 | u.7 | u.8 | u.9) == 0
    }
}

extension KeyframeTemplate {
    /// The template with new key ids (a copy that is edited on its own).
    public func withFreshKeyIDs() -> KeyframeTemplate {
        var c = self
        for i in c.tracks.indices {
            c.tracks[i].track.keys = c.tracks[i].track.keys.map { var k = $0; k.id = UUID(); return k }
        }
        return c
    }

    /// Equal apart from key ids (a Custom animation against the preset or saved one it came from).
    public func sameCurves(as other: KeyframeTemplate) -> Bool {
        func strip(_ t: KeyframeTemplate) -> KeyframeTemplate {
            var c = t
            for i in c.tracks.indices {
                c.tracks[i].track.keys = c.tracks[i].track.keys.enumerated().map { n, k in
                    var k = k; k.id = AnimationTrack.keyID(n); return k
                }
            }
            return c
        }
        return strip(self) == strip(other)
    }

    /// What Custom starts from when the side was Off: a plain fade over `AnimationSet.customLength`.
    public static func customStart(_ side: AnimationSide) -> KeyframeTemplate {
        let d = AnimationSet.customLength
        return KeyframeTemplate(tracks: [
            AnimationTrack(property: "opacity", keys: side == .intro ? [(.zero, 0, .linear), (d, 1, .linear)]
                                                                     : [(.zero, 1, .linear), (d, 0, .linear)]),
        ], duration: d, anchor: side == .intro ? .start : .end).withFreshKeyIDs()
    }

    /// True once a key carries an id of its own: the template was made Custom (`withFreshKeyIDs`) and is edited by hand.
    /// Presets number their keys per track (`AnimationTrack.keyID`).
    public var hasOwnKeyIDs: Bool {
        tracks.contains { $0.track.keys.contains { let u = $0.id.uuid; return (u.0 | u.1 | u.2 | u.3 | u.4 | u.5) != 0 } }
    }

    /// The same animation whatever the frame it was built for: equal apart from key ids, and each Position track may
    /// differ by one positive factor (a saved animation stores Position as a fraction of the frame, so its pixels
    /// change with the sequence format).
    public func sameShape(as other: KeyframeTemplate) -> Bool {
        guard duration == other.duration, anchor == other.anchor, loops == other.loops, textAnimator == other.textAnimator,
              tracks.count == other.tracks.count else { return false }
        for a in tracks {
            guard let b = other.track(for: a.property), a.track.keys.count == b.track.keys.count else { return false }
            let position = a.property == "positionX" || a.property == "positionY"
            let na = position ? a.track.keys.reduce(0) { max($0, abs($1.value)) } : 1
            let nb = position ? b.track.keys.reduce(0) { max($0, abs($1.value)) } : 1
            guard (na == 0) == (nb == 0) else { return false }
            for (x, y) in zip(a.track.keys, b.track.keys) {
                guard x.time == y.time, x.interpolation == y.interpolation, x.inHandle == y.inHandle, x.outHandle == y.outHandle
                else { return false }
                let u = na == 0 ? 0 : x.value / na, v = nb == 0 ? 0 : y.value / nb
                guard abs(u - v) <= 1e-6 else { return false }
            }
        }
        return true
    }
}

/// A saved Custom animation is a keystone (`PresetKind.keystone`): the same store as every other keyframe building block.
extension Keystone {
    private static func key<A, B>(_ k: Keyframe<A>, id: UUID, _ value: B) -> Keyframe<B> {
        Keyframe(id: id, time: k.time, value: value, interpolation: k.interpolation, inHandle: k.inHandle, outHandle: k.outHandle)
    }

    /// The side of an item's animation this keystone can play: one that starts with the clip or ends with it.
    public var animationSide: AnimationSide? {
        switch anchor {
        case .clipStart: .intro
        case .clipEnd: .outro
        case .free: nil
        }
    }

    /// Saves one side of an animation. Position becomes a fraction of `frameSize`, Scale a factor, as a keystone stores
    /// them. Nil when the side keys nothing. The text animator is not part of it (it is chosen on its own).
    public init?(animation t: KeyframeTemplate, side: AnimationSide, name: String, frameSize: Vec2) {
        guard t.duration > .zero, t.tracks.contains(where: { !$0.track.isEmpty }) else { return nil }
        self.init(name: name, duration: t.duration, anchor: side == .intro ? .clipStart : .clipEnd)
        if t.loops { loops = true }
        func member(_ n: String) -> AnimatedProperty<Double> {
            AnimatedProperty(AnimationParam.rest(ofTrack: n), track: t.track(for: n)?.track ?? KeyframeTrack())
        }
        let w = frameSize.x == 0 ? 1 : frameSize.x, h = frameSize.y == 0 ? 1 : frameSize.y
        let p = KeyframesPair.editable(member("positionX"), member("positionY")).track
        if !p.isEmpty { position = KeyframeTrack(keys: p.keys.map { Self.key($0, id: UUID(), Vec2($0.value.x / w, $0.value.y / h)) }) }
        let s = member("scale").track
        if !s.isEmpty { scale = KeyframeTrack(keys: s.keys.map { Self.key($0, id: UUID(), Vec2($0.value, $0.value)) }) }
        let r = member("rotation").track
        if !r.isEmpty { rotation = KeyframeTrack(keys: r.keys.map { Self.key($0, id: UUID(), $0.value) }) }
        let o = member("opacity").track
        if !o.isEmpty { opacity = KeyframeTrack(keys: o.keys.map { Self.key($0, id: UUID(), $0.value) }) }
    }

    /// The keystone as one side of an item's animation (keys numbered like a preset's); nil for a free keystone or an
    /// empty one. Position is `frameSize` pixels, Scale its X factor.
    public func animationTemplate(frameSize: Vec2) -> KeyframeTemplate? {
        guard let side = animationSide, duration > .zero else { return nil }
        var tracks: [AnimationTrack] = []
        func add<V>(_ name: String, _ t: KeyframeTrack<V>?, _ value: (V) -> Double) {
            guard let t, !t.isEmpty else { return }
            tracks.append(AnimationTrack(property: name, track: KeyframeTrack(keys: t.keys.enumerated().map { n, k in
                var key = Self.key(k, id: AnimationTrack.keyID(n), value(k.value))
                easing?.apply(to: &key)          // the keystone's own curve replaces each key's shape, as on apply
                return key
            })))
        }
        add("opacity", opacity) { $0 }
        add("scale", scale) { $0.x }
        add("positionX", position) { $0.x * frameSize.x }
        add("positionY", position) { $0.y * frameSize.y }
        add("rotation", rotation) { $0 }
        guard !tracks.isEmpty else { return nil }
        var t = KeyframeTemplate(tracks: tracks, duration: duration, anchor: side == .intro ? .start : .end)
        t.loops = loops == true
        return t
    }
}
