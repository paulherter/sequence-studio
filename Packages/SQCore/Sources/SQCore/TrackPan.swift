import Foundation

/// Track fader and pan: the one definition used by playback, scrubbing and export (the feeder applies it to every
/// audio track bus), so the mix is identical everywhere. Gain in dB is the track fader; pan is -1 (left) ... +1 (right).
public enum TrackPan {
    public static let minVolumeDB = -60.0
    public static let maxVolumeDB = 15.0

    /// (left, right) gain of the pan control. Never above unity, so panning cannot clip what the fader left clean.
    /// - Stereo sources (`stereoSource`): a balance control. The center is unity on both sides; panning attenuates only the
    ///   opposite side, linearly (pan 0.5 right = left at 0.5), hard right silences the left channel.
    /// - Mono sources: equal power, `sin`/`cos` of the pan angle scaled to unity at the center and capped at unity. The loud
    ///   side stays at unity and the far side falls off with the power law (hard left: left 1, right 0). The mono law is
    ///   continuous through the center (no step when the slider crosses 0), unlike a -3 dB center that would make an
    ///   untouched track quieter than a panned one.
    public static func gains(pan: Double, stereoSource: Bool = true) -> (left: Double, right: Double) {
        let p = min(max(pan, -1), 1)
        if p == 0 { return (1, 1) }               // exact center (cos/sin of pi/4 are not exactly 1/sqrt(2))
        if stereoSource { return p < 0 ? (1, 1 + p) : (1 - p, 1) }
        let a = (p + 1) * .pi / 4
        let k = 2.0.squareRoot()
        return (min(1, cos(a) * k), min(1, sin(a) * k))
    }

    /// Fader dB to linear gain; at or below the floor the track is silent.
    public static func linear(volumeDB db: Double) -> Double {
        db <= minVolumeDB ? 0 : pow(10, min(db, maxVolumeDB) / 20)
    }

    /// Final per-channel gain of a track: fader times pan. (1, 1) for an untouched track.
    public static func channelGains(volumeDB: Double, pan: Double, stereoSource: Bool = true) -> (left: Double, right: Double) {
        let g = linear(volumeDB: volumeDB), p = gains(pan: pan, stereoSource: stereoSource)
        return (g * p.left, g * p.right)
    }
}

/// What a clip is, for default loudness (`Clip.audioTag`).
public enum AudioTag: String, Sendable, Codable, CaseIterable {
    case dialogue, music, sfx

    public var title: String {
        switch self { case .dialogue: "Dialogue"; case .music: "Music"; case .sfx: "SFX" }
    }

    /// THE loudness table (E8): Gain sheet, Match Loudness, voice chain readout, role chain and delivery targets read it.
    /// Integrated loudness target for web delivery. Dialogue -14 LUFS (YouTube/TikTok reference); music and effects
    /// sit 6 dB below the dialogue so speech stays on top.
    public var targetLUFS: Double {
        switch self { case .dialogue: -14; case .music, .sfx: -20 }
    }
}
