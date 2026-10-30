import Foundation

// Posterize Time: the clip shows one source frame for 1/rate s, then jumps (a stepped look, e.g. 8 fps on 25 fps footage).
// It is a time remap, not a pixel effect: the layer's source time is quantized in `Timeline.videoLayers`, so playback, scrub and
// export read exactly the same frames and the GPU does nothing extra (a held frame is the same decoded frame, decode cache hit).
// Kind and keys are stored strings: never rename.

extension ClipEffect {
    public static let posterizeTimeKind = "posterizeTime"
    public static let posterizeRateKey = "posterizeRate"
}

public enum PosterizeTime {
    public static let rateRange: ClosedRange<Double> = 1...60
    public static let defaultRate = 8.0

    /// The start of the hold interval (clip-local, rational) that contains `local`, for `rate` frames per second. The rate is
    /// taken in hundredths so a non-integer rate stays exact. A `local` before the clip start is returned unchanged.
    public static func heldLocal(_ local: Time, rate: Double) -> Time {
        guard !local.isNegative, rate.isFinite else { return local }
        let n = Int64((min(max(rate, rateRange.lowerBound), rateRange.upperBound) * 100).rounded())
        // index = floor(local * rate); held = index / rate
        let index = (Int128(local.value) * Int128(n)) / (Int128(100) * Int128(local.timescale))
        return Time(reducing: index * 100, Int128(n))
    }
}

extension Clip {
    /// The enabled Posterize Time rate at timeline time `t` (the last such effect wins), nil when the clip has none.
    func posterizeRate(at t: Time) -> Double? {
        guard let e = effects.last(where: { $0.kind == ClipEffect.posterizeTimeKind && $0.enabled }) else { return nil }
        return e.scalar(ClipEffect.posterizeRateKey, atLocal: t - start)
    }

    /// `t` moved back to the start of its hold interval; `t` itself without Posterize Time or outside the clip.
    /// With `frameDuration`, a held half of a transition (outside the clip, no media beyond that edge) posterizes the
    /// clip's edge frame it reads (`heldReadTime`): the result is the start of that frame's interval, inside the clip.
    func posterizedTime(at t: Time, frameDuration fd: Time? = nil) -> Time {
        let read = fd.map { heldReadTime(at: t, frameDuration: $0) } ?? t
        guard timeline.contains(read), let rate = posterizeRate(at: read) else { return t }
        return start + PosterizeTime.heldLocal(read - start, rate: rate)
    }
}

extension EffectCatalog {
    static let posterizeTime: [EffectSpec] = [
        EffectSpec(kind: ClipEffect.posterizeTimeKind, title: "Posterize Time", params: [
            EffectParamSpec(key: ClipEffect.posterizeRateKey, title: "Frame Rate", unit: "fps",
                            defaultValue: PosterizeTime.defaultRate, range: PosterizeTime.rateRange, step: 1, decimals: 0),
        ]),
    ]
}
