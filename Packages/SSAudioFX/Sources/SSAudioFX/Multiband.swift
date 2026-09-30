import Foundation

/// Own 4-band compressor: three Linkwitz-Riley 4th-order crossovers (allpass-compensated so the
/// bands sum flat), a linked peak detector per band, per-band threshold/ratio/attack/release/gain.
///
/// Sample-by-sample with all state in the value, so the output never depends on chunking and the
/// same code serves offline rendering and realtime playback. Zero latency.
struct MultibandCompressor {
    // MARK: filters

    private struct Coef { var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0 }

    private struct Biquad {
        var z1 = 0.0, z2 = 0.0
        @inline(__always) mutating func run(_ x: Double, _ c: Coef) -> Double {
            let y = c.b0 * x + z1
            z1 = c.b1 * x - c.a1 * y + z2
            z2 = c.b2 * x - c.a2 * y
            return y
        }
    }

    /// LR4 low/high pair at one frequency (two cascaded Butterworth biquads each).
    private struct Crossover {
        var lp = Coef(), hp = Coef()
        init() {}
        init(freq: Double, sampleRate: Double) {
            let w = 2 * Double.pi * freq / sampleRate
            let cw = cos(w), alpha = sin(w) / (2 * 0.5.squareRoot())        // Q = 1/sqrt(2)
            let a0 = 1 + alpha
            let a1 = -2 * cw / a0, a2 = (1 - alpha) / a0
            lp = Coef(b0: (1 - cw) / 2 / a0, b1: (1 - cw) / a0, b2: (1 - cw) / 2 / a0, a1: a1, a2: a2)
            hp = Coef(b0: (1 + cw) / 2 / a0, b1: -(1 + cw) / a0, b2: (1 + cw) / 2 / a0, a1: a1, a2: a2)
        }
    }

    private struct Split {
        var l1 = Biquad(), l2 = Biquad(), h1 = Biquad(), h2 = Biquad()
        @inline(__always) mutating func run(_ x: Double, _ c: Crossover) -> (lo: Double, hi: Double) {
            (l2.run(l1.run(x, c.lp), c.lp), h2.run(h1.run(x, c.hp), c.hp))
        }
        /// lo + hi: the LR4 allpass at this crossover.
        @inline(__always) mutating func allpass(_ x: Double, _ c: Crossover) -> Double {
            let r = run(x, c); return r.lo + r.hi
        }
    }

    private struct ChannelFilters {
        var s1 = Split(), s2 = Split(), s3 = Split()
        var apLow2 = Split(), apLow3 = Split(), apMid3 = Split()
    }

    struct BandState {
        var threshold = 1.0           // linear
        var slope = 0.0               // 1 - 1/ratio
        var hold = 0.0                // detector decay per sample
        var attack = 0.0, release = 0.0
        var gain = 1.0                // band gain, linear
        var env = 0.0                 // peak detector, linear
        var gr = 0.0                  // smoothed gain reduction, dB (>= 0)
    }

    // MARK: state

    private let active: Bool
    private let x1: Crossover, x2: Crossover, x3: Crossover
    private let preGain: Double, makeup: Double
    private var filters: [ChannelFilters]
    private var bands: [BandState]

    init(settings raw: MultibandCompressorSettings, sampleRate: Double, channels: Int) {
        let s = raw.normalized(sampleRate: sampleRate)
        active = !s.bypass
        x1 = Crossover(freq: s.crossoversHz[0], sampleRate: sampleRate)
        x2 = Crossover(freq: s.crossoversHz[1], sampleRate: sampleRate)
        x3 = Crossover(freq: s.crossoversHz[2], sampleRate: sampleRate)
        preGain = AudioGain.linear(fromDB: s.preGainDB)
        makeup = AudioGain.linear(fromDB: s.makeupGainDB)
        filters = Array(repeating: ChannelFilters(), count: max(1, channels))
        // Detector decay follows the band's lowest frequency (one period), bounded to 3...20 ms,
        // so the peak ripple stays small without slowing the detector down.
        let lowEdges = [s.crossoversHz[0] / 2, s.crossoversHz[0], s.crossoversHz[1], s.crossoversHz[2]]
        bands = (0..<4).map { i in
            let b = s.bands[i]
            var st = BandState()
            st.threshold = pow(10, b.thresholdDB / 20)
            st.slope = 1 - 1 / b.ratio
            let holdS = min(0.02, max(0.003, 1 / lowEdges[i]))
            st.hold = exp(-1 / (holdS * sampleRate))
            st.attack = exp(-1 / (max(0.0001, b.attackMs / 1000) * sampleRate))
            st.release = exp(-1 / (max(0.0001, b.releaseMs / 1000) * sampleRate))
            st.gain = AudioGain.linear(fromDB: b.gainDB)
            return st
        }
    }

    mutating func process(_ buf: inout [[Float]]) {
        guard active, let n = buf.first?.count, n > 0 else { return }
        let chans = min(buf.count, filters.count)
        var v = [SIMD4<Double>](repeating: .zero, count: chans)
        for i in 0..<n {
            for c in 0..<chans {
                let x = Double(buf[c][i]) * preGain
                let a = filters[c].s1.run(x, x1)
                let b = filters[c].s2.run(a.hi, x2)
                let d = filters[c].s3.run(b.hi, x3)
                let b0 = filters[c].apLow3.allpass(filters[c].apLow2.allpass(a.lo, x2), x3)
                let b1 = filters[c].apMid3.allpass(b.lo, x3)
                v[c] = SIMD4(b0, b1, d.lo, d.hi)
            }
            var g = SIMD4<Double>(repeating: 1)
            for k in 0..<4 {
                var peak = 0.0
                for c in 0..<chans { peak = max(peak, abs(v[c][k])) }
                g[k] = bands[k].step(peak: peak)
            }
            for c in 0..<chans {
                let y = (v[c] * g).sum() * makeup
                buf[c][i] = Float(y)
            }
        }
    }
}

extension MultibandCompressor.BandState {
    /// Advances the detector and gain smoothing by one sample, returns the linear band gain.
    mutating func step(peak: Double) -> Double {
        env = max(peak, env * hold)
        var target = 0.0
        if env > threshold { target = 20 * log10(env / threshold) * slope }
        let coef = target > gr ? attack : release
        gr = coef * gr + (1 - coef) * target
        if gr < 1e-9 { gr = 0; return gain }
        return gain * exp(-gr * 0.11512925464970229)        // 10^(-gr/20)
    }
}

extension MultibandCompressorSettings {
    /// Clamps to usable values: crossovers within 20 Hz...0.45*rate and strictly ascending, ratio >= 1.
    func normalized(sampleRate: Double) -> MultibandCompressorSettings {
        var s = self
        let neutral = MultibandCompressorSettings.neutral
        if s.bands.count != 4 { s.bands = neutral.bands }
        if s.crossoversHz.count != 3 { s.crossoversHz = neutral.crossoversHz }
        let hi = sampleRate * 0.45
        var x = s.crossoversHz.map { min(hi, max(20, $0.isNaN ? 20 : $0)) }
        for i in 1..<3 where x[i] <= x[i - 1] { x[i] = min(hi, x[i - 1] * 1.05) }
        for i in 1..<3 where x[i] <= x[i - 1] { x[i - 1] = x[i] / 1.05 }
        s.crossoversHz = x
        for i in 0..<4 {
            s.bands[i].ratio = s.bands[i].ratio.isNaN ? 1 : max(1, s.bands[i].ratio)
            s.bands[i].thresholdDB = min(0, max(-100, s.bands[i].thresholdDB.isNaN ? 0 : s.bands[i].thresholdDB))
            s.bands[i].gainDB = min(40, max(-40, s.bands[i].gainDB.isNaN ? 0 : s.bands[i].gainDB))
        }
        return s
    }
}
