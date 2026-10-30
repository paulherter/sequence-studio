import Foundation
import SQCore

// Creator stages of the per-clip chain: Stereo Width (mid/side) and Chorus. Plain DSP, state preallocated, `process` never
// allocates, zero latency (the chorus's wet copy is a delay, not look-ahead, so nothing is compensated).

/// Mid/side width. Only the first two channels are touched; a mono clip passes. The width moves linearly across the block.
final class StereoWidthStage {
    func reset() {}

    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int, from w0: Double, to w1: Double) {
        guard chs >= 2 else { return }
        let a = Float(max(0, w0)), step = (Float(max(0, w1)) - a) / Float(n)
        let l = buf[0], r = buf[1]
        for i in 0..<n {
            let w = a + step * Float(i)
            let m = (l[i] + r[i]) * 0.5, s = (l[i] - r[i]) * 0.5 * w
            l[i] = m + s; r[i] = m - s
        }
    }
}

/// Chorus: per channel a delay line read at 15 ms +- depth by a sine LFO (linear interpolation), the right channel a quarter
/// cycle behind the left. Output = dry + (wet - dry) * mix. The line is sized for the largest sweep, so nothing allocates.
final class ChorusStage {
    private let fs: Double, channels: Int
    private static let baseMs = 15.0, maxDepthMs = 10.0
    private let size: Int
    private var line: [Float]
    private var pos = 0
    private var phase = 0.0
    var wasOff = false
    init(sampleRate: Double, channels: Int) {
        fs = sampleRate; self.channels = channels
        size = Int((Self.baseMs + Self.maxDepthMs) * 0.001 * sampleRate) + 4
        line = [Float](repeating: 0, count: size * channels)
    }
    func reset() { for i in line.indices { line[i] = 0 }; pos = 0; phase = 0 }

    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                 rateHz: Double, depthMs: Double, mixFrom m0: Double, to m1: Double) {
        if wasOff { reset(); wasOff = false }
        let base = Self.baseMs * 0.001 * fs, depth = min(max(depthMs, 0), Self.maxDepthMs) * 0.001 * fs
        let inc = max(rateHz, 0) / fs
        let mixA = Float(min(max(m0, 0), 1)), mixStep = (Float(min(max(m1, 0), 1)) - mixA) / Float(n)
        let count = min(chs, channels)
        for i in 0..<n {
            let mix = mixA + mixStep * Float(i)
            for c in 0..<count {
                let ph = phase + (c % 2 == 1 ? 0.25 : 0)
                let d = base + depth * sin(2 * Double.pi * ph)
                let dry = buf[c][i]
                line[c * size + pos] = dry
                var rp = Double(pos) - d
                if rp < 0 { rp += Double(size) }
                var i0 = Int(rp)
                if i0 >= size { i0 -= size }
                let f = Float(max(0, rp - Double(i0))), i1 = i0 + 1 >= size ? 0 : i0 + 1
                let wet = line[c * size + i0] * (1 - f) + line[c * size + i1] * f
                buf[c][i] = dry + (wet - dry) * mix
            }
            pos += 1; if pos == size { pos = 0 }
            phase += inc; if phase >= 1 { phase -= 1 }
        }
    }
}
