import Foundation
import SQCore
import SQAudioFX

extension AudioFeeder {
    /// Fader and pan of the top-level track `id` as per-channel linear gain: (1, 1) for an untouched or unknown track.
    /// The single place the track mix is read, so playback, scrubbing and export cannot differ.
    static func trackFader(timeline: Timeline, track id: Track.ID, monoSource: Bool = false) -> (left: Double, right: Double) {
        guard let t = timeline.track(id), t.volumeDB != 0 || t.pan != 0 else { return (1, 1) }
        return TrackPan.channelGains(volumeDB: t.volumeDB, pan: t.pan, stereoSource: !monoSource)
    }

    /// Pan only (fader at unity) of the top-level track: applied per segment with the source's own law, before the track FX.
    static func trackPanOnly(timeline: Timeline, track id: Track.ID, monoSource: Bool) -> (left: Double, right: Double) {
        guard let t = timeline.track(id), t.pan != 0 else { return (1, 1) }
        return TrackPan.channelGains(volumeDB: 0, pan: t.pan, stereoSource: !monoSource)
    }

    /// Fader gain only (linear, no pan) of the top-level track: applied after the track FX.
    static func trackFaderGain(timeline: Timeline, track id: Track.ID) -> Double {
        guard let t = timeline.track(id), t.volumeDB != 0 else { return 1 }
        return TrackPan.linear(volumeDB: t.volumeDB)
    }

    /// Fader and pan of every track the segment passes through, inner mix first, then the enclosing nest clips' tracks
    /// outwards: the product of their per-channel gains. A segment of the top sequence has just its own track.
    /// `skipTop`: the top-level track contributes its pan only; its fader gain is applied after that track's effects.
    /// `below`: only the tracks inside the nest `seg.nests[below]` (the ones that mix before that nest clip's effects).
    static func faderChain(_ seg: AudioSegment, top: Timeline, sequences: [Timeline.ID: Timeline], monoSource: Bool,
                           below: Int? = nil, skipTop: Bool = false, at: Time = .zero) -> (left: Double, right: Double) {
        var l = 1.0, r = 1.0
        var t = at                                  // time inside `owner` at the segment start (Sequence Volume keys)
        func apply(_ owner: Timeline?, _ track: Track.ID) {
            guard let owner else { return }
            let f = trackFader(timeline: owner, track: track, monoSource: monoSource)
            l *= f.left; r *= f.right
        }
        var owner: Timeline? = top
        for (j, n) in seg.nests.enumerated() {      // outermost first: each nest's track lives in the previous level's sequence
            if below.map({ j > $0 }) ?? true {
                if skipTop && j == 0, let owner { let f = Self.trackPanOnly(timeline: owner, track: n.track, monoSource: monoSource); l *= f.left; r *= f.right }
                else { apply(owner, n.track) }
            }
            owner = n.clip.sequence.flatMap { sequences[$0] }
            t = n.clip.sourceInstant(atLocal: t - n.clip.start)
            // The nested sequence's own Sequence Volume: on its summed sound, i.e. inside the nest clip (before its effects).
            // shortcut: a keyed nested level is read at the segment start (`at`, clamped into the block; ramped from the
            // previous block like a fader), not per sample; upgrade when keyed nested levels need sample accuracy.
            if below.map({ j >= $0 }) ?? true, let g = owner?.masterGain(at: t), g != 1 { l *= g; r *= g }
        }
        if skipTop && seg.nests.isEmpty, let owner {
            let f = Self.trackPanOnly(timeline: owner, track: seg.track, monoSource: monoSource); l *= f.left; r *= f.right
        } else { apply(owner, seg.track) }
        return (l, r)
    }

    /// Faders of the tracks holding `seg.nests[0...depth]` (the effected nest's summed, stereo output passes them).
    /// `above`: the nest plays inside the effected nest `seg.nests[above]`: only the tracks and Sequence Volumes between
    /// the two (the ones that mix before that outer nest clip's effects).
    static func nestFader(_ seg: AudioSegment, depth: Int, above: Int? = nil, top: Timeline, sequences: [Timeline.ID: Timeline],
                          skipTop: Bool = false, at: Time = .zero) -> (left: Double, right: Double) {
        var l = 1.0, r = 1.0
        var t = at
        var owner: Timeline? = top
        for (j, n) in seg.nests[...depth].enumerated() {
            if let owner, above.map({ j > $0 }) ?? true {
                let f = skipTop && j == 0 ? trackPanOnly(timeline: owner, track: n.track, monoSource: false)
                                          : trackFader(timeline: owner, track: n.track, monoSource: false)
                l *= f.left; r *= f.right
            }
            owner = n.clip.sequence.flatMap { sequences[$0] }
            t = n.clip.sourceInstant(atLocal: t - n.clip.start)
            // Sequence Volume of the enclosing nested sequences (nest `depth`'s own one ran before its effects).
            if j < depth, above.map({ j >= $0 }) ?? true, let g = owner?.masterGain(at: t), g != 1 { l *= g; r *= g }
        }
        return (l, r)
    }

    /// Key of the remembered fader gain of one bus: the top-level track, and whether the segment's media is mono (the pan law differs).
    struct FaderKey: Hashable { var track: Track.ID; var mono: Bool }
}

extension AudioFeeder {
    static func roles(of t: Timeline) -> [UUID: AudioTag] {
        var out: [UUID: AudioTag] = [:]
        for tr in t.tracks where tr.kind == .audio { if let r = tr.audioRole { out[tr.id] = r } }
        return out
    }

    /// Master limiter ceiling of a sequence: its delivery target's true-peak ceiling, nil without a target.
    static func limiterCeiling(of t: Timeline) -> Double? { t.deliveryTarget?.truePeakDB }

    /// The preset a track's FX runs: the explicit one, else its role's voiced preset, else none.
    public func effectivePreset(track id: Track.ID) -> TrackAudioPreset? { config.withLock { $0.effectivePreset(id) } }
}

extension AudioFeeder.FXConfig {
    func effectivePreset(_ id: UUID) -> TrackAudioPreset? { presets[id] ?? roles[id].map(TrackAudioPreset.forRole) }
}
