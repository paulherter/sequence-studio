import Foundation

extension Timeline {
    /// Frames by which linked clips have drifted apart (Premiere's red out-of-sync badge). Only video and audio clips
    /// of the same linked group that play the same media count: the video clip is the reference, the audio clip shows
    /// `+n` when it plays n frames later than it should and the video clip shows `-n` (the opposite).
    /// Clips that are in sync (or less than half a frame off) are absent.
    public func syncOffsets() -> [Clip.ID: Int64] {
        var groups: [UUID: [Clip]] = [:]
        for c in tracks.flatMap(\.clips) { if let l = c.link, !c.isGenerator { groups[l, default: []].append(c) } }
        var out: [Clip.ID: Int64] = [:]
        for clips in groups.values {
            guard let v = clips.first(where: { $0.kind == .video }) else { continue }
            let vShift = v.start - v.source.start
            for a in clips where a.kind == .audio && a.media == v.media {
                let d = (a.start - a.source.start) - vShift
                let frames = Self.roundedFrames(d, frameDuration)
                if frames != 0 { out[a.id] = frames; out[v.id] = -frames }
            }
        }
        return out
    }

    /// Nearest whole number of frames (half away from zero), exact on rational time.
    static func roundedFrames(_ d: Time, _ frame: Time) -> Int64 {
        // d / frame = (d.value * frame.timescale) / (d.timescale * frame.value)
        let n = Int128(d.value) * Int128(frame.timescale), m = Int128(d.timescale) * Int128(frame.value)
        guard m != 0 else { return 0 }
        let q = (abs(n) * 2 + m) / (2 * m)
        return Int64(n < 0 ? -q : q)
    }
}
