import Foundation
import SQCore

extension AudioFeeder {
    /// Fader and pan of the top-level track `id` as per-channel linear gain: (1, 1) for an untouched or unknown track.
    /// The single place the track mix is read, so playback, scrubbing and export cannot differ.
    static func trackFader(timeline: Timeline, track id: Track.ID, monoSource: Bool = false) -> (left: Double, right: Double) {
        guard let t = timeline.track(id), t.volumeDB != 0 || t.pan != 0 else { return (1, 1) }
        return TrackPan.channelGains(volumeDB: t.volumeDB, pan: t.pan, stereoSource: !monoSource)
    }

    /// Fader and pan of every track the segment passes through, inner mix first, then the enclosing nest clips' tracks
    /// outwards: the product of their per-channel gains. A segment of the top sequence has just its own track.
    static func faderChain(_ seg: AudioSegment, top: Timeline, sequences: [Timeline.ID: Timeline], monoSource: Bool) -> (left: Double, right: Double) {
        var l = 1.0, r = 1.0
        func apply(_ owner: Timeline?, _ track: Track.ID) {
            guard let owner else { return }
            let f = trackFader(timeline: owner, track: track, monoSource: monoSource)
            l *= f.left; r *= f.right
        }
        var owner: Timeline? = top
        for n in seg.nests {                        // outermost first: each nest's track lives in the previous level's sequence
            apply(owner, n.track)
            owner = n.clip.sequence.flatMap { sequences[$0] }
        }
        apply(owner, seg.track)
        return (l, r)
    }

    /// Key of the remembered fader gain of one bus: the top-level track, and whether the segment's media is mono (the pan law differs).
    struct FaderKey: Hashable { var track: Track.ID; var mono: Bool }
}
