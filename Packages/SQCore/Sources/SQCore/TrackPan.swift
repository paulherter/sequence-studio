import Foundation

/// Track fader and pan: the one definition used by playback, scrubbing and export (the feeder applies it to every
/// audio track bus), so the mix is identical everywhere.
public enum TrackPan {
    public static let minVolumeDB = -60.0
    public static let maxVolumeDB = 15.0

    /// (left, right) gain for a stereo bus, constant power: left^2 + right^2 stays 2, so the centre is exactly unity
    /// (0 dB) and hard left silences the right channel (the left side is lifted by 3 dB, the usual constant-power law).
    public static func gains(pan: Double) -> (left: Double, right: Double) {
        let p = min(max(pan, -1), 1)
        if p == 0 { return (1, 1) }               // exact centre (cos/sin of pi/4 are not exactly 1/sqrt(2))
        let a = (p + 1) * .pi / 4
        let k = 2.0.squareRoot()
        return (cos(a) * k, sin(a) * k)
    }

    /// Fader dB to linear gain; at or below the floor the track is silent.
    public static func linear(volumeDB db: Double) -> Double {
        db <= minVolumeDB ? 0 : pow(10, min(db, maxVolumeDB) / 20)
    }

    /// Final per-channel gain of a track: fader times pan. (1, 1) for an untouched track.
    public static func channelGains(volumeDB: Double, pan: Double) -> (left: Double, right: Double) {
        let g = linear(volumeDB: volumeDB), p = gains(pan: pan)
        return (g * p.left, g * p.right)
    }
}

/// What a clip is, for default loudness (`Clip.audioTag`).
public enum AudioTag: String, Sendable, Codable, CaseIterable {
    case dialogue, music, sfx

    public var title: String {
        switch self { case .dialogue: "Dialogue"; case .music: "Music"; case .sfx: "SFX" }
    }

    /// Integrated loudness target for web delivery. Dialogue -14 LUFS (YouTube/TikTok reference); music and effects
    /// sit 6 dB below the dialogue so speech stays on top.
    public var targetLUFS: Double {
        switch self { case .dialogue: -14; case .music, .sfx: -20 }
    }
}
