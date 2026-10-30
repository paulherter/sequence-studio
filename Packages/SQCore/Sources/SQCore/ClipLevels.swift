import Foundation

/// How loud a clip is HEARD, per window of timeline time: the source level (peak, supplied by the caller) mapped through
/// the clip's own time mapping (reverse, constant speed, speed ramps), times Audio Gain, the volume line and the track fader.
/// Silence and dialogue detection read this, so a pause is a pause as played, not as stored in the file.
public enum ClipLevels {
    /// About 10 ms windows, an exact fraction of the clip duration (no Double time).
    public static func window(for duration: Time) -> (window: Time, count: Int) {
        // Capped at 1e9 windows (~116 days) so an absurd (corrupt) duration cannot trap the Int conversion.
        let n = max(1, Int(min((Double(duration.value) / Double(duration.timescale) * 100).rounded(.up), 1e9)))
        return (Time.scaled(duration, by: 1, over: Int64(n)), n)
    }

    /// Audible level (linear) of every window of `clip`, in clip-local order; windows are `window` long.
    /// `sourcePeak` returns the linear peak of the media in a source time range (any channel).
    public static func audible(of clip: Clip, trackVolumeDB: Double = 0,
                               sourcePeak: (TimeRange) -> Float) -> (levels: [Float], window: Time) {
        let dur = clip.timeline.duration
        guard dur > .zero else { return ([], dur) }
        let (w, n) = window(for: dur)
        let track = Float(TrackPan.linear(volumeDB: trackVolumeDB))
        let minSpan = Time(1, 1000)
        var levels: [Float] = []
        levels.reserveCapacity(n)
        for i in 0..<n {
            let a = w * Int64(i), b = w * Int64(i + 1)
            var src = clip.sourceRange(fromLocal: a, toLocal: b)
            if src.duration < minSpan { src = TimeRange(start: src.start, duration: minSpan) }
            let heard = Float(clip.volume(at: clip.start + Time.scaled(w, by: Int64(2 * i + 1), over: 2)))
            levels.append(sourcePeak(src) * heard * track)
        }
        return (levels, w)
    }
}
