import Foundation

/// Portable peaks (no Accelerate): the scalar twin of `PeakAccumulator` and the pyramid of mip levels, so Windows builds
/// the same `WaveformData` the Mac builds. The Mac keeps the vDSP accumulator for its decode path.
public struct ScalarPeakAccumulator: Sendable {
    public let channels: Int
    public let bucketSize: Int
    /// Sample frames added so far.
    public private(set) var frames = 0
    private var base: [Float] = []
    private var lo: [Float], hi: [Float]
    private var inBucket = 0

    public init(channels: Int, bucketSize: Int) {
        precondition(channels > 0 && bucketSize > 0)
        self.channels = channels
        self.bucketSize = bucketSize
        lo = [Float](repeating: .greatestFiniteMagnitude, count: channels)
        hi = [Float](repeating: -.greatestFiniteMagnitude, count: channels)
    }

    /// One buffer per channel, each `frames` long.
    public mutating func add(planar ptrs: [UnsafePointer<Float>], frames n: Int) {
        precondition(ptrs.count == channels)
        var f = 0
        while f < n {
            let take = min(bucketSize - inBucket, n - f)
            for c in 0..<channels {
                let p = ptrs[c] + f
                var mn = lo[c], mx = hi[c]
                for i in 0..<take {
                    let v = p[i]
                    if v < mn { mn = v }
                    if v > mx { mx = v }
                }
                lo[c] = mn; hi[c] = mx
            }
            inBucket += take
            f += take
            if inBucket == bucketSize { flush() }
        }
        frames += max(n, 0)
    }

    private mutating func flush() {
        for c in 0..<channels {
            base.append(lo[c]); base.append(hi[c])
            lo[c] = .greatestFiniteMagnitude; hi[c] = -.greatestFiniteMagnitude
        }
        inBucket = 0
    }

    /// Level 0 (`[b0c0min, b0c0max, b0c1min, ...]`), the last partial bucket included.
    public mutating func finish() -> [Float] {
        if inBucket > 0 { flush() }
        return base
    }
}

public enum PeakPyramid {
    /// The next coarser level: each pair of buckets becomes one (min of mins, max of maxes); an odd last bucket stays.
    public static func mip(_ src: [Float], channels: Int) -> [Float] {
        let stride = 2 * channels
        let n = src.count / stride
        let m = (n + 1) / 2
        var dst = [Float](repeating: 0, count: m * stride)
        for i in 0..<m {
            for c in 0..<channels {
                let a = (2 * i) * stride + c * 2
                var l = src[a], h = src[a + 1]
                if 2 * i + 1 < n {
                    let b = (2 * i + 1) * stride + c * 2
                    l = min(l, src[b]); h = max(h, src[b + 1])
                }
                dst[i * stride + c * 2] = l; dst[i * stride + c * 2 + 1] = h
            }
        }
        return dst
    }

    /// Level 0 plus mip levels down to two buckets, as `Waveform.build` returns them.
    public static func waveform(level0: [Float], channels: Int, frames: Int, bucketSize: Int, sampleRate: Int) -> WaveformData {
        var levels = [level0]
        while levels[levels.count - 1].count / (2 * channels) > 2 {
            levels.append(mip(levels[levels.count - 1], channels: channels))
        }
        return WaveformData(sampleRate: sampleRate, channelCount: channels, totalFrames: frames, baseBucketSize: bucketSize, levels: levels)
    }

    /// Peaks of an `AudioSource` (decoded at `sampleRate`), read start to end in chunks; a mono source gives one channel.
    /// nil when canceled.
    public static func waveform(from source: any AudioSource, sampleRate: Int, baseBucketSize: Int = WaveformData.defaultBaseBucketSize,
                                chunk: Int = 1 << 16, isCancelled: () -> Bool = { false }) throws -> WaveformData? {
        let channels = source.isMono ? 1 : 2
        var acc = ScalarPeakAccumulator(channels: channels, bucketSize: baseBucketSize)
        var bufs = (0..<channels).map { _ in [Float](repeating: 0, count: chunk) }
        var at: Int64 = 0
        while true {
            if isCancelled() { return nil }
            var n = 0
            for c in 0..<channels {
                let got = try bufs[c].withUnsafeMutableBufferPointer { try source.read(from: at, count: chunk, into: $0.baseAddress!, channel: c) }
                n = c == 0 ? got : min(n, got)
            }
            guard n > 0 else { break }
            if channels == 1 {
                bufs[0].withUnsafeBufferPointer { acc.add(planar: [$0.baseAddress!], frames: n) }
            } else {
                bufs[0].withUnsafeBufferPointer { l in bufs[1].withUnsafeBufferPointer { r in acc.add(planar: [l.baseAddress!, r.baseAddress!], frames: n) } }
            }
            at += Int64(n)
            if n < chunk { break }
        }
        let frames = acc.frames
        let level0 = acc.finish()
        guard !level0.isEmpty else { throw WaveformError.noAudioTrack }
        return waveform(level0: level0, channels: channels, frames: frames, bucketSize: baseBucketSize, sampleRate: sampleRate)
    }
}
