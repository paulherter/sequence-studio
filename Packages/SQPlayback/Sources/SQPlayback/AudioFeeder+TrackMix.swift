import Foundation
import SQCore

extension AudioFeeder {
    /// Fader and pan of the top-level track `id` as per-channel linear gain: (1, 1) for an untouched or unknown track.
    /// The single place the track mix is read, so playback, scrubbing and export cannot differ.
    static func trackFader(timeline: Timeline, track id: Track.ID) -> (left: Double, right: Double) {
        guard let t = timeline.track(id), t.volumeDB != 0 || t.pan != 0 else { return (1, 1) }
        return TrackPan.channelGains(volumeDB: t.volumeDB, pan: t.pan)
    }
}
