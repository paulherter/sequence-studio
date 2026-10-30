import Accelerate
import Foundation
import SQCore

/// Non-ML beat tracker: log-magnitude spectral flux onset envelope, autocorrelation tempo with a log-normal prior around
/// 120 BPM, dynamic-programming beat tracking (Ellis 2007) and a downbeat phase picked by accumulated onset strength.
///
/// shortcut: assumes a fixed meter (`beatsPerBar`, default 4) and a roughly steady tempo; no ML model is shipped. The
/// MIT-licensed "Beat This!" model (CPJKU) is the upgrade path, it needs a Core ML conversion first (docs/THIRD_PARTY.md).
public enum BeatDetector {
    public struct Settings: Sendable, Equatable {
        public var minimumBPM = 60.0
        public var maximumBPM = 200.0
        public var beatsPerBar = 4
        /// How strongly beats are pulled toward the tempo period (higher = more rigid).
        public var tightness = 100.0
        public init() {}
    }

    static let fftSize = 1024

    /// Mono samples at `sampleRate`. Returns nil for silence, noise without a pulse, or less than three seconds.
    public static func analyze(samples: [Float], sampleRate: Int, settings s: Settings = Settings()) -> BeatGrid? {
        guard sampleRate > 0, s.beatsPerBar > 0, samples.count >= sampleRate * 3 else { return nil }
        let hop = max(1, Int((Double(sampleRate) / 100).rounded()))
        var env = onsetEnvelope(samples: samples, hop: hop)
        guard env.count > 100 else { return nil }
        normalize(&env)
        guard let period = tempoPeriod(env: env, fps: Double(sampleRate) / Double(hop), settings: s) else { return nil }
        let frames = trackBeats(env: env, period: period, tightness: s.tightness)
        guard frames.count >= 4 else { return nil }
        let phase = downbeatPhase(frames: frames, env: env, beatsPerBar: s.beatsPerBar)
        // Onset flux peaks about a quarter window before the event (Hann slope), so shift forward.
        let bias = fftSize / 4
        let beats = frames.map { Time(Int64($0 * hop + bias), Int64(sampleRate)) }
        let downs = Array(stride(from: phase, to: beats.count, by: s.beatsPerBar))
        let bpm = 60.0 * Double(sampleRate) / Double(hop) / period
        return BeatGrid(beats: beats, downbeatBeatIndices: downs, beatsPerBar: s.beatsPerBar, bpm: bpm)
    }

    // MARK: - Onset envelope

    static func onsetEnvelope(samples: [Float], hop: Int) -> [Float] {
        let n = fftSize, half = n / 2, log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let frameCount = samples.count / hop
        var prev = [Float](repeating: 0, count: half)
        var out = [Float](repeating: 0, count: frameCount)
        var buf = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        for f in 0..<frameCount {
            let start = f * hop - half
            for k in 0..<n {
                let idx = start + k
                buf[k] = (idx >= 0 && idx < samples.count) ? samples[idx] * window[k] : 0
            }
            buf.withUnsafeBufferPointer { b in
                re.withUnsafeMutableBufferPointer { r in
                    im.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        b.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                    }
                }
            }
            var flux: Float = 0
            for k in 1..<half {
                let m = log1p(mag[k])
                flux += max(0, m - prev[k])
                prev[k] = m
            }
            out[f] = flux
        }
        return out
    }

    /// Subtracts a ~0.5 s moving mean, clamps at 0, scales to unit standard deviation.
    static func normalize(_ env: inout [Float]) {
        let n = env.count, w = 25
        var cum = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { cum[i + 1] = cum[i] + Double(env[i]) }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - w), hi = min(n, i + w + 1)
            let mean = (cum[hi] - cum[lo]) / Double(hi - lo)
            out[i] = max(0, env[i] - Float(mean))
        }
        var sum = 0.0, sq = 0.0
        for v in out { sum += Double(v); sq += Double(v) * Double(v) }
        let mean = sum / Double(n), sd = (sq / Double(n) - mean * mean).squareRoot()
        if sd < 1e-4 { env = [Float](repeating: 0, count: n); return }
        env = out.map { $0 / Float(sd) }
    }

    // MARK: - Tempo

    /// Beat period in frames (fractional), or nil when the envelope has no pulse.
    static func tempoPeriod(env: [Float], fps: Double, settings s: Settings) -> Double? {
        let n = env.count
        let minLag = max(2, Int((60 * fps / s.maximumBPM).rounded(.down)))
        let maxLag = min(n / 2, Int((60 * fps / s.minimumBPM).rounded(.up)))
        guard minLag < maxLag else { return nil }
        func acf(_ lag: Int) -> Double {
            var d: Float = 0
            let shifted = Array(env[lag...])
            vDSP_dotpr(env, 1, shifted, 1, &d, vDSP_Length(n - lag))
            return Double(d) / Double(n - lag)
        }
        var scores = [Double](repeating: 0, count: maxLag + 2)
        for lag in (minLag - 1)...(maxLag + 1) where lag >= 1 && lag < n { scores[lag] = acf(lag) }
        var best = -1.0, bestLag = 0
        for lag in minLag...maxLag {
            let bpm = 60 * fps / Double(lag)
            let o = log2(bpm / 120) / 0.8
            let v = scores[lag] * exp(-0.5 * o * o)
            if v > best { best = v; bestLag = lag }
        }
        guard bestLag > 0, best > 0.02 else { return nil }
        // Parabolic refinement of the autocorrelation peak.
        let a = scores[bestLag - 1], b = scores[bestLag], c = scores[bestLag + 1]
        let denom = a - 2 * b + c
        let shift = abs(denom) > 1e-9 ? 0.5 * (a - c) / denom : 0
        return Double(bestLag) + max(-1, min(1, shift))
    }

    // MARK: - Beat tracking

    static func trackBeats(env: [Float], period: Double, tightness: Double) -> [Int] {
        let n = env.count
        var score = env.map { Double($0) }
        var back = [Int](repeating: -1, count: n)
        let lo = max(1, Int((period / 2).rounded(.down))), hi = Int((period * 2).rounded(.up))
        for i in 0..<n where i - lo >= 0 {
            var best = 0.0, arg = -1
            for j in max(0, i - hi)...(i - lo) {
                let r = log(Double(i - j) / period)
                let v = score[j] - tightness * r * r
                if arg < 0 || v > best { best = v; arg = j }
            }
            if arg >= 0, best > 0 { score[i] = Double(env[i]) + best; back[i] = arg }
        }
        let tail = max(0, n - Int(period * 1.5))
        var cur = (tail..<n).max { score[$0] < score[$1] } ?? n - 1
        var frames: [Int] = []
        while cur >= 0 { frames.append(cur); cur = back[cur] }
        frames.reverse()
        // Beats placed in silence at either end carry no onset: drop them.
        func strength(_ f: Int) -> Float {
            var m: Float = 0
            for k in max(0, f - 2)...min(n - 1, f + 2) { m = max(m, env[k]) }
            return m
        }
        let sorted = frames.map(strength).sorted()
        guard !sorted.isEmpty else { return [] }
        let floor = sorted[sorted.count / 2] * 0.25
        while let f = frames.first, strength(f) < floor { frames.removeFirst() }
        while let f = frames.last, strength(f) < floor { frames.removeLast() }
        return frames
    }

    // MARK: - Downbeat

    /// The beat phase (0..<beatsPerBar) whose beats carry the most onset strength on average.
    static func downbeatPhase(frames: [Int], env: [Float], beatsPerBar: Int) -> Int {
        guard beatsPerBar > 1 else { return 0 }
        var sum = [Double](repeating: 0, count: beatsPerBar), cnt = [Int](repeating: 0, count: beatsPerBar)
        for (i, f) in frames.enumerated() {
            var m: Float = 0
            for k in max(0, f - 2)...min(env.count - 1, f + 2) { m = max(m, env[k]) }
            sum[i % beatsPerBar] += Double(m); cnt[i % beatsPerBar] += 1
        }
        var best = 0, bestV = -1.0
        for p in 0..<beatsPerBar where cnt[p] > 0 {
            let v = sum[p] / Double(cnt[p])
            if v > bestV + 1e-9 { bestV = v; best = p }
        }
        return best
    }
}
