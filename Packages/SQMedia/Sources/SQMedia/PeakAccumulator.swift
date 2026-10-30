import Accelerate

/// Min/max per `bucketSize` frames per channel (`WaveformData` level 0), fed in chunks of any size. Same result as a
/// per-sample `if v < lo` / `if v > hi` loop (min and max are exact), but each bucket slice is one `vDSP_minv` /
/// `vDSP_maxv` per channel (strided over interleaved frames). NaN samples are the only difference: the scalar loop
/// skipped them, vDSP may return NaN for that bucket (no decoder we use produces NaN).
struct PeakAccumulator {
    let channels: Int
    let bucketSize: Int
    /// Sample frames added so far.
    private(set) var frames = 0
    private var base: [Float] = []
    private var lo: [Float], hi: [Float]
    private var inBucket = 0

    init(channels: Int, bucketSize: Int) {
        precondition(channels > 0 && bucketSize > 0)
        self.channels = channels
        self.bucketSize = bucketSize
        lo = [Float](repeating: .greatestFiniteMagnitude, count: channels)
        hi = [Float](repeating: -.greatestFiniteMagnitude, count: channels)
    }

    /// Interleaved frames: `frames * channels` floats.
    mutating func add(interleaved p: UnsafePointer<Float>, frames n: Int) {
        let ch = channels
        add(frames: n) { c, from, count in (p + from * ch + c, ch) }
    }

    /// One buffer per channel, each `frames` long.
    mutating func add(planar ptrs: [UnsafePointer<Float>], frames n: Int) {
        precondition(ptrs.count == channels)
        add(frames: n) { c, from, _ in (ptrs[c] + from, 1) }
    }

    private mutating func add(frames n: Int, _ slice: (_ channel: Int, _ from: Int, _ count: Int) -> (UnsafePointer<Float>, Int)) {
        guard n > 0 else { return }
        var f = 0
        while f < n {
            let take = min(bucketSize - inBucket, n - f)
            for c in 0..<channels {
                let (p, stride) = slice(c, f, take)
                var mn: Float = 0, mx: Float = 0
                vDSP_minv(p, vDSP_Stride(stride), &mn, vDSP_Length(take))
                vDSP_maxv(p, vDSP_Stride(stride), &mx, vDSP_Length(take))
                if mn < lo[c] { lo[c] = mn }
                if mx > hi[c] { hi[c] = mx }
            }
            inBucket += take
            f += take
            if inBucket == bucketSize { flush() }
        }
        frames += n
    }

    private mutating func flush() {
        for c in 0..<channels {
            base.append(lo[c]); base.append(hi[c])
            lo[c] = .greatestFiniteMagnitude; hi[c] = -.greatestFiniteMagnitude
        }
        inBucket = 0
    }

    /// Level 0 (`[b0c0min, b0c0max, b0c1min, ...]`), the last partial bucket included.
    mutating func finish() -> [Float] {
        if inBucket > 0 { flush() }
        return base
    }
}
