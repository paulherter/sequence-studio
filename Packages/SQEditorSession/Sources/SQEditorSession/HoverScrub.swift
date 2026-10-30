import SQCore

/// Pure maths of hover scrubbing an icon: where the pointer is inside the thumbnail picks the time in the media.
public enum HoverScrub {
    /// Time at `fraction` (0...1, clamped) of `duration`, snapped to `frameDuration`, never past the last frame.
    public static func time(fraction: Double, duration: Time, frameDuration: Time) -> Time {
        guard duration > .zero, frameDuration.value > 0 else { return .zero }
        let f = min(max(fraction, 0), 1)
        let scale: Int64 = 1_000
        let raw = Time(Int64((f * Double(scale)).rounded()) * duration.value, scale * duration.timescale)
        let last = max(.zero, duration - frameDuration)
        return min(raw.snapped(to: frameDuration), last)
    }

    /// Poster frame: 10 % into the media, at most 2 s (a clip often starts black).
    public static func poster(duration: Time, frameDuration: Time) -> Time {
        min(time(fraction: 0.1, duration: duration, frameDuration: frameDuration), Time(2, 1))
    }
}
