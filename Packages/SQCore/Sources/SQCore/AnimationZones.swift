import Foundation

// Animation zones (feedback 2026-10-05, TEMPLATE-ECOSYSTEM T1/T2): an intro zone at the clip start and an outro zone at its
// end keep their absolute length when the clip is trimmed or stretched; the middle holds or stretches. Premiere calls this
// Responsive Design - Time. Ours is auto-detected from the first/last keyframes and works on any clip, with or without a
// title template. Stored on the clip (`Clip.zones`, v58) as lengths, so a trim never has to rewrite them.
//
// Two users of the same record:
// - Any keyed clip: a trim moves the outro keys with the clip end and leaves the intro keys at the clip start
//   (`Clip.extendHead` / `extendTail`, through `keyTime(_:from:to:edge:)`).
// - A nested template clip: the inner sequence is played through `contentTime(atLocal:duration:)` instead of the source
//   range, so the content itself is never moved (`Clip.innerTime`).

public struct AnimationZones: Sendable, Hashable, Codable {
    /// What happens between the zones when the clip length changes.
    public enum Middle: String, Sendable, Hashable, Codable {
        /// The middle plays at its own speed and then holds on the outro's first frame (longer clip), or is cut (shorter).
        case hold
        /// The middle is time-scaled to fill the space between the zones.
        case stretch
    }

    /// End of the intro zone, from the clip start.
    public var introEnd: Time
    /// Length of the outro zone, ending at the clip end.
    public var outroLength: Time
    public var middle: Middle
    /// The length the content was made for (a title template's duration). Needed to play nested content through the
    /// zones; nil for a plain keyed clip (its keys are moved instead).
    public var designDuration: Time?

    public init(introEnd: Time, outroLength: Time, middle: Middle = .hold, designDuration: Time? = nil) {
        self.introEnd = max(introEnd, .zero)
        self.outroLength = max(outroLength, .zero)
        self.middle = middle
        self.designDuration = designDuration
    }

    /// Zones given as positions inside content of `designDuration` (introEnd, outroStart).
    public init(introEnd: Time, outroStart: Time, designDuration: Time, middle: Middle = .hold) {
        self.init(introEnd: introEnd, outroLength: designDuration - outroStart, middle: middle, designDuration: designDuration)
    }

    /// Start of the outro zone in a clip of `duration`.
    public func outroStart(in duration: Time) -> Time { duration - outroLength }

    /// Auto-detect: keys in the first half of `duration` belong to the intro (it ends at the last of them), keys in the
    /// second half to the outro (it starts at the first of them). nil without keys or for an empty duration.
    public static func detect(keyTimes: [Time], duration: Time, middle: Middle = .hold,
                              designDuration: Time? = nil) -> AnimationZones? {
        guard duration > .zero, !keyTimes.isEmpty else { return nil }
        let half = duration.halved
        let intro = keyTimes.filter { $0 <= half }.max().map { min(max($0, .zero), duration) } ?? .zero
        let outro = keyTimes.filter { $0 > half }.min().map { min($0, duration) } ?? duration
        return AnimationZones(introEnd: intro, outroLength: duration - outro, middle: middle, designDuration: designDuration)
    }

    /// Content time (nested template) shown at clip-local `local` in a clip of `duration`. Intro: 1:1 from the start.
    /// Outro: 1:1 ending at the content end. Middle: `middle`. A clip shorter than both zones cuts the intro; the outro
    /// always plays whole. Without `designDuration` the clip's own time is returned.
    public func contentTime(atLocal local: Time, duration: Time) -> Time {
        guard let design = designDuration else { return local }
        let outOuter = outroStart(in: duration), outInner = outroStart(in: design)
        if local >= outOuter { return outInner + (local - outOuter) }
        if local <= introEnd { return local }
        switch middle {
        case .hold:
            return min(local, outInner)
        case .stretch:
            let spanOuter = outOuter - introEnd, spanInner = outInner - introEnd
            guard spanOuter > .zero, spanInner > .zero else { return min(local, max(outInner, introEnd)) }
            return introEnd + Time.scaled(local - introEnd, by: spanInner, over: spanOuter)
        }
    }

    /// Where a clip-local key at `t` goes when a trim changes the clip from `old` to `new` duration at `edge`.
    /// Intro keys stay, outro keys keep their distance to the clip end, middle keys hold their frames (`hold`) or scale
    /// into the new middle (`stretch`).
    public func keyTime(_ t: Time, from old: Time, to new: Time, edge: ClipEdge) -> Time {
        let g = new - old
        if t <= introEnd { return t }
        if t >= outroStart(in: old) { return t + g }
        switch middle {
        case .hold:
            return edge == .head ? t + g : t
        case .stretch:
            let a = outroStart(in: old) - introEnd, b = outroStart(in: new) - introEnd
            guard a > .zero, b > .zero else { return edge == .head ? t + g : t }
            return introEnd + Time.scaled(t - introEnd, by: b, over: a)
        }
    }
}

extension Clip {
    /// Zones auto-detected from this clip's keyframes (transform, opacity, volume, effect parameters); nil without keys.
    public var detectedZones: AnimationZones? {
        AnimationZones.detect(keyTimes: keyframeTimes, duration: duration)
    }

    /// A nested clip whose inner sequence plays through its zones (an applied title template).
    var playsThroughZones: Bool { sequence != nil && zones?.designDuration != nil && holdFrame == nil }

    /// Moves the clip-local keys for a trim from `old` to `new` duration at `edge` through the zones.
    mutating func remapKeysThroughZones(_ z: AnimationZones, from old: Time, to new: Time, edge: ClipEdge) {
        let f: (Time) -> Time = { z.keyTime($0, from: old, to: new, edge: edge) }
        animation = animation.remapped(f)
        effects = effects.map { $0.remapped(f) }
        remapVariantKeys(f)
    }
}

extension Project {
    /// Sets (nil: removes) the animation zones of a clip. Throws `.clipNotFound`, `.trackLocked`.
    public mutating func setAnimationZones(_ zones: AnimationZones?, clip id: Clip.ID) throws {
        try modifyClipForZones(id) { $0.zones = zones }
    }

    /// Turns zones on for a clip, detected from its keyframes (a nested template clip keeps its design duration and
    /// middle mode). Throws `TitleTemplateError.noKeyframes` when the clip has no keys.
    public mutating func autoDetectAnimationZones(clip id: Clip.ID) throws {
        try modifyClipForZones(id) { c in
            guard var z = c.detectedZones else { throw TitleTemplateError.noKeyframes }
            if let old = c.zones { z.middle = old.middle; z.designDuration = old.designDuration }
            c.zones = z
        }
    }

    mutating func modifyClipForZones(_ id: Clip.ID, _ body: (inout Clip) throws -> Void) throws {
        for ti in timelines.indices {
            for tr in timelines[ti].tracks.indices {
                guard var c = timelines[ti].tracks[tr].clips.first(where: { $0.id == id }) else { continue }
                if timelines[ti].tracks[tr].isLocked { throw EditError.trackLocked }
                try body(&c)
                timelines[ti].tracks[tr].replace(c)
                return
            }
        }
        throw EditError.clipNotFound
    }
}
