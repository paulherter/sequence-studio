import Foundation

// Noise Gate, Delay and Reverb stages of the per-clip chain (`ClipAudioFXChain`). Plain-Float DSP, all state preallocated in
// `init`; `process` never allocates. Playback and export run the same code (one chain type).

/// Downward gate, stereo-linked: the level follows the loudest channel (fast rise, 10 ms fall so it does not chatter on
/// waveform dips); the gain glides to 1 (open) or to the range floor (closed) with the attack and release times.
final class NoiseGateStage {
    private var core = GateCore<Float>(detector: .smoothedFall, smoothing: .lerp)
    private let fs: Double
    private let decay: Float
    var wasOff = false

    init(sampleRate: Double) {
        fs = sampleRate
        decay = Float(exp(-1 / (0.010 * sampleRate)))
    }
    func reset() { core.reset() }

    /// `holdMs`: after the level fell below the threshold the gate stays open this long before it starts to close (0 = no hold).
    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                 thresholdFrom t0: Double, to t1: Double, attackMs: Double, releaseMs: Double, rangeFrom r0: Double, to r1: Double,
                 holdMs: Double = 0) {
        if wasOff { reset(); wasOff = false }
        let holdSamples = Int((holdMs.isNaN ? 0 : min(max(holdMs, 0), 1_000)) / 1000 * fs)
        // A keyframed Hold going down shortens a hold that is already running.
        core.hold = min(core.hold, holdSamples)
        let atk = Float(exp(-1 / (max(0.0001, attackMs / 1000) * fs)))
        let rel = Float(exp(-1 / (max(0.0001, releaseMs / 1000) * fs)))
        let inv = 1 / Double(n)
        for i in 0..<n {
            let t = Double(i) * inv
            let thr = Float(pow(10, (t0 + (t1 - t0) * t) / 20))
            let floorGain = Float(pow(10, -abs(r0 + (r1 - r0) * t) / 20))
            var peak: Float = 0
            for c in 0..<chs { peak = max(peak, abs(buf[c][i])) }
            let gain = core.step(peak: peak, openLevel: thr, closeLevel: thr, floorGain: floorGain, decay: decay,
                                 attack: atk, release: rel, holdSamples: holdSamples)
            for c in 0..<chs { buf[c][i] *= gain }
        }
    }
}

/// Feedback delay with a 2 s line per channel. The delay time glides (at most 0.05 sample per sample) so changing it does not
/// click; reads interpolate linearly. Mix crossfades dry and delayed sound; feedback feeds the delayed sound back.
final class DelayStage {
    static let maxSeconds = 2.0
    private let size: Int
    private let line: UnsafeMutablePointer<Float>   // channels * size
    private var pos = 0
    private var current: Double = -1                 // in samples, -1 = not set yet
    private let channels: Int
    private let fs: Double
    var wasOff = false

    init(sampleRate: Double, channels: Int) {
        fs = sampleRate; self.channels = channels
        size = Int(Self.maxSeconds * sampleRate) + 8
        line = .allocate(capacity: size * channels)
        line.initialize(repeating: 0, count: size * channels)
    }
    deinit { line.deallocate() }
    func reset() { line.update(repeating: 0, count: size * channels); pos = 0; current = -1 }

    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                 timeFrom t0: Double, to t1: Double, feedbackFrom f0: Double, to f1: Double, mixFrom m0: Double, to m1: Double) {
        if wasOff { reset(); wasOff = false }
        let maxDelay = Double(size - 4)
        func samples(_ ms: Double) -> Double { min(max(ms * 0.001 * fs, 1), maxDelay) }
        if current < 0 { current = samples(t0) }
        var cur = current
        let inv = 1 / Double(n)
        var p = pos
        // The same delay for every channel (the stereo image stays put).
        for i in 0..<n {
            let t = Double(i) * inv
            let target = samples(t0 + (t1 - t0) * t)
            cur += min(0.05, max(-0.05, target - cur))
            let fb = Float(min(0.95, max(0, f0 + (f1 - f0) * t))), mix = Float(min(1, max(0, m0 + (m1 - m0) * t)))
            var rp = Double(p) - cur
            if rp < 0 { rp += Double(size) }
            let i0 = Int(rp), frac = Float(rp - Double(i0)), i1 = i0 + 1 == size ? 0 : i0 + 1
            for c in 0..<min(chs, channels) {
                let l = line + c * size
                let delayed = l[i0] * (1 - frac) + l[i1] * frac
                let x = buf[c][i]
                l[p] = x + delayed * fb
                buf[c][i] = x * (1 - mix) + delayed * mix
            }
            p += 1
            if p == size { p = 0 }
        }
        pos = p; current = cur
    }
}

/// Freeverb (Jezar, public domain): per channel 8 parallel damped feedback combs into 4 series allpasses; odd channel
/// indexes (the right one) use delays 23 samples longer for a stereo image. The input is the mean of all channels.
final class ReverbStage {
    private static let combTunings = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allpassTunings = [556, 441, 341, 225]
    private static let spread = 23
    private struct Comb { var offset: Int, length: Int, pos = 0, store: Float = 0 }
    private struct Allpass { var offset: Int, length: Int, pos = 0 }
    private var combs: [Comb] = []        // channels * 8, fixed size after init
    private var allpasses: [Allpass] = [] // channels * 4
    private let memory: UnsafeMutablePointer<Float>
    private let memoryCount: Int
    private let channels: Int
    var wasOff = false

    init(sampleRate: Double, channels: Int) {
        self.channels = channels
        let scale = sampleRate / 44_100
        var off = 0
        for c in 0..<channels {
            let extra = (c % 2) * Self.spread
            for t in Self.combTunings {
                let len = Int(Double(t + extra) * scale)
                combs.append(Comb(offset: off, length: len)); off += len
            }
            for t in Self.allpassTunings {
                let len = Int(Double(t + extra) * scale)
                allpasses.append(Allpass(offset: off, length: len)); off += len
            }
        }
        memoryCount = off
        memory = .allocate(capacity: max(1, off))
        memory.initialize(repeating: 0, count: max(1, off))
    }
    deinit { memory.deallocate() }
    func reset() {
        memory.update(repeating: 0, count: memoryCount)
        for i in combs.indices { combs[i].pos = 0; combs[i].store = 0 }
        for i in allpasses.indices { allpasses[i].pos = 0 }
    }

    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                 room: Double, damping: Double, mixFrom m0: Double, to m1: Double) {
        if wasOff { reset(); wasOff = false }
        let feedback = Float(0.7 + 0.28 * min(1, max(0, room)))
        let damp = Float(0.4 * min(1, max(0, damping)))
        let inGain: Float = 0.015, wetScale: Float = 3
        let used = min(chs, channels)
        let inv = 1 / Double(n)
        let meanScale = 1 / Float(max(1, used))
        let mem = memory
        for i in 0..<n {
            let mix = Float(min(1, max(0, m0 + (m1 - m0) * Double(i) * inv)))
            var sum: Float = 0
            for c in 0..<used { sum += buf[c][i] }
            let input = sum * meanScale * inGain
            for c in 0..<used {
                var acc: Float = 0
                for k in 0..<8 {
                    let ci = c * 8 + k
                    let p = combs[ci].offset + combs[ci].pos
                    let out = mem[p]
                    combs[ci].store = out * (1 - damp) + combs[ci].store * damp
                    mem[p] = input + combs[ci].store * feedback
                    combs[ci].pos += 1
                    if combs[ci].pos == combs[ci].length { combs[ci].pos = 0 }
                    acc += out
                }
                for k in 0..<4 {
                    let ai = c * 4 + k
                    let p = allpasses[ai].offset + allpasses[ai].pos
                    let bufout = mem[p]
                    let out = -acc + bufout
                    mem[p] = acc + bufout * 0.5
                    allpasses[ai].pos += 1
                    if allpasses[ai].pos == allpasses[ai].length { allpasses[ai].pos = 0 }
                    acc = out
                }
                buf[c][i] = buf[c][i] * (1 - mix) + acc * wetScale * mix
            }
        }
    }
}
