import Foundation

/// Copied keyframes of several properties as relative times plus easing.
public struct KeyframeClipboard: Sendable, Hashable, Codable {
    public struct Key<V: KeyframeValue>: Sendable, Hashable, Codable {
        public var relativeTime: Time
        public var value: V
        public var interpolation: Interpolation
        public var inHandle: EaseHandle
        public var outHandle: EaseHandle
        public var inTangent: Vec2
        public var outTangent: Vec2

        init(_ k: Keyframe<V>, origin: Time) {
            relativeTime = k.time - origin; value = k.value; interpolation = k.interpolation
            inHandle = k.inHandle; outHandle = k.outHandle; inTangent = k.inTangent; outTangent = k.outTangent
        }

        func keyframe(at origin: Time) -> Keyframe<V> {
            Keyframe(time: origin + relativeTime, value: value, interpolation: interpolation,
                     inHandle: inHandle, outHandle: outHandle, inTangent: inTangent, outTangent: outTangent)
        }
    }

    public enum Track: Sendable, Hashable, Codable {
        case scalar([Key<Double>])
        case vector([Key<Vec2>])
        case color([Key<EffectColor>])
        case path([Key<MaskPath>])
    }

    public private(set) var tracks: [PropertyID: Track]

    init(tracks: [PropertyID: Track]) { self.tracks = tracks }

    /// Copies the selected keys (per property). `nil` if nothing is selected.
    public static func copy(from source: [PropertyID: PropertyTrack], selection: [PropertyID: Set<UUID>]) -> KeyframeClipboard? {
        var earliest: Time?
        for (p, ids) in selection {
            for k in source[p]?.times ?? [] where ids.contains(k.id) { earliest = earliest.map { min($0, k.time) } ?? k.time }
        }
        guard let origin = earliest else { return nil }
        var out: [PropertyID: Track] = [:]
        for (p, ids) in selection {
            switch source[p] {
            case .scalar(let t)?:
                let ks = Self.keys(of: t, ids, origin: origin)
                if !ks.isEmpty { out[p] = .scalar(ks) }
            case .vector(let t)?:
                let ks = Self.keys(of: t, ids, origin: origin)
                if !ks.isEmpty { out[p] = .vector(ks) }
            case .color(let t)?:
                let ks = Self.keys(of: t, ids, origin: origin)
                if !ks.isEmpty { out[p] = .color(ks) }
            case .path(let t)?:
                let ks = Self.keys(of: t, ids, origin: origin)
                if !ks.isEmpty { out[p] = .path(ks) }
            case nil: break
            }
        }
        return out.isEmpty ? nil : KeyframeClipboard(tracks: out)
    }

    private static func keys<V>(of t: KeyframeTrack<V>, _ ids: Set<UUID>, origin: Time) -> [Key<V>] {
        t.keys.filter { ids.contains($0.id) }.map { Key($0, origin: origin) }
    }

    private static func pasted<V>(_ ks: [Key<V>], at time: Time, within range: ClosedRange<Time>?) -> [Keyframe<V>] {
        ks.filter { range?.contains(time + $0.relativeTime) ?? true }.map { $0.keyframe(at: time) }
    }

    /// The vector keys copied for `property` pasted into the two members of an X/Y pair row (`KeyframesPair.paste`),
    /// with the times and the range of `paste(into:at:within:)`. False without vector keys for it.
    @discardableResult
    public func pastePair(_ property: PropertyID, x: inout AnimatedProperty<Double>, y: inout AnimatedProperty<Double>,
                          at time: Time, within range: ClosedRange<Time>? = nil) -> Bool {
        guard case .vector(let ks)? = tracks[property] else { return false }
        KeyframesPair.paste(Self.pasted(ks, at: time, within: range), x: &x, y: &y)
        return true
    }

    /// Keys outside `range` (clip-local, e.g. the clip's extent) are dropped.
    /// Pastes so the earliest copied key lands at `time`; keys at identical times are replaced.
    /// A missing target property gets a new track. Returns false and changes nothing if any
    /// target property has a different value type.
    @discardableResult
    public func paste(into target: inout [PropertyID: PropertyTrack], at time: Time, within range: ClosedRange<Time>? = nil) -> Bool {
        for (p, clip) in tracks {
            switch (clip, target[p]) {
            case (_, nil), (.scalar, .scalar?), (.vector, .vector?), (.color, .color?), (.path, .path?): break
            default: return false
            }
        }
        for (p, clip) in tracks {
            switch clip {
            case .scalar(let ks):
                var tr: KeyframeTrack<Double>
                if case .scalar(let existing)? = target[p] { tr = existing } else { tr = KeyframeTrack() }
                for k in Self.pasted(ks, at: time, within: range) { tr.insert(k) }
                target[p] = .scalar(tr)
            case .vector(let ks):
                var tr: KeyframeTrack<Vec2>
                if case .vector(let existing)? = target[p] { tr = existing } else { tr = KeyframeTrack() }
                for k in Self.pasted(ks, at: time, within: range) { tr.insert(k) }
                target[p] = .vector(tr)
            case .color(let ks):
                var tr: KeyframeTrack<EffectColor>
                if case .color(let existing)? = target[p] { tr = existing } else { tr = KeyframeTrack() }
                for k in Self.pasted(ks, at: time, within: range) { tr.insert(k) }
                target[p] = .color(tr)
            case .path(let ks):
                var tr: KeyframeTrack<MaskPath>
                if case .path(let existing)? = target[p] { tr = existing } else { tr = KeyframeTrack() }
                for k in Self.pasted(ks, at: time, within: range) { tr.insert(k) }
                target[p] = .path(tr)
            }
        }
        return true
    }
}
