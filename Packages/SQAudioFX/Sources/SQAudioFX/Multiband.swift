import Foundation
import SQCore

/// Own 4-band compressor: three Linkwitz-Riley 4th-order crossovers (allpass-compensated so the
/// bands sum flat), a linked peak detector per band, per-band threshold/ratio/attack/release/gain.
///
/// Sample-by-sample with all state in the value, so the output never depends on chunking and the
/// same code serves offline rendering and realtime playback. Zero latency.
struct MultibandCompressor {
    // MARK: filters

    fileprivate struct Coef { var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0 }

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
    fileprivate struct Crossover {
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

    /// Everything `settings` decides, precomputed without touching filter/detector state.
    /// Plain value (no arrays), so it can be built on any thread and applied on the render thread allocation-free.
    struct Config {
        fileprivate var active = false
        fileprivate var x1 = Crossover(), x2 = Crossover(), x3 = Crossover()
        fileprivate var preGain = 1.0, makeup = 1.0
        fileprivate var b0 = BandState(), b1 = BandState(), b2 = BandState(), b3 = BandState()
        /// Band solo / bypass targets: `audible` 1 = heard, 0 = muted by another band's solo; `bypass` 1 = band passes
        /// uncompressed at unity (no band gain). Both fade with `fadeCoef` (5 ms one-pole) so a switch never clicks.
        fileprivate var audible = SIMD4<Double>(repeating: 1), bypass = SIMD4<Double>(repeating: 0)
        fileprivate var fadeCoef = 0.0

        init(settings raw: MultibandCompressorSettings, sampleRate: Double) {
            let s = raw.normalized(sampleRate: sampleRate)
            fadeCoef = exp(-1 / (0.005 * sampleRate))
            active = !s.bypass
            x1 = Crossover(freq: s.crossoversHz[0], sampleRate: sampleRate)
            x2 = Crossover(freq: s.crossoversHz[1], sampleRate: sampleRate)
            x3 = Crossover(freq: s.crossoversHz[2], sampleRate: sampleRate)
            preGain = GainMath.linear(fromDB: s.preGainDB)
            makeup = GainMath.linear(fromDB: s.makeupGainDB)
            // Detector decay follows the band's lowest frequency (one period), bounded to 3...20 ms,
            // so the peak ripple stays small without slowing the detector down.
            let lowEdges = [s.crossoversHz[0] / 2, s.crossoversHz[0], s.crossoversHz[1], s.crossoversHz[2]]
            func make(_ i: Int) -> BandState {
                let b = s.bands[i]
                var st = BandState()
                st.threshold = pow(10, b.thresholdDB / 20)
                st.slope = 1 - 1 / b.ratio
                let holdS = min(0.02, max(0.003, 1 / lowEdges[i]))
                st.hold = exp(-1 / (holdS * sampleRate))
                st.attack = exp(-1 / (max(0.0001, b.attackMs / 1000) * sampleRate))
                st.release = exp(-1 / (max(0.0001, b.releaseMs / 1000) * sampleRate))
                st.gain = GainMath.linear(fromDB: b.gainDB)
                return st
            }
            b0 = make(0); b1 = make(1); b2 = make(2); b3 = make(3)
        }

        /// Same result as `init(settings:sampleRate:)` for one clip effect's values, without allocating (no arrays). Crossovers
        /// are clamped to 20 Hz...0.45 x rate and made ascending, ratio >= 1, threshold -100...0 dB, band gain +-40 dB.
        init(values v: AudioMultibandValues, sampleRate: Double) {
            active = true
            fadeCoef = exp(-1 / (0.005 * sampleRate))
            for i in 0..<4 {
                if v.bandSolo != 0 { audible[i] = v.isSoloed(i) ? 1 : 0 }
                bypass[i] = v.isBypassed(i) ? 1 : 0
            }
            let hi = sampleRate * 0.45
            var x = SIMD3<Double>(v.crossoverHz[0], v.crossoverHz[1], v.crossoverHz[2])
            for i in 0..<3 { x[i] = min(hi, max(20, x[i].isNaN ? 20 : x[i])) }
            for i in 1..<3 where x[i] <= x[i - 1] { x[i] = min(hi, x[i - 1] * 1.05) }
            for i in 1..<3 where x[i] <= x[i - 1] { x[i - 1] = x[i] / 1.05 }
            x1 = Crossover(freq: x[0], sampleRate: sampleRate)
            x2 = Crossover(freq: x[1], sampleRate: sampleRate)
            x3 = Crossover(freq: x[2], sampleRate: sampleRate)
            preGain = 1
            makeup = GainMath.linear(fromDB: v.outputGainDB)
            let lowEdges = SIMD4<Double>(x[0] / 2, x[0], x[1], x[2])
            func make(_ i: Int) -> BandState {
                var st = BandState()
                let ratio = v.ratio[i].isNaN ? 1 : max(1, v.ratio[i])
                st.threshold = pow(10, min(0, max(-100, v.thresholdDB[i].isNaN ? 0 : v.thresholdDB[i])) / 20)
                st.slope = 1 - 1 / ratio
                let holdS = min(0.02, max(0.003, 1 / lowEdges[i]))
                st.hold = exp(-1 / (holdS * sampleRate))
                st.attack = exp(-1 / (max(0.0001, v.attackMs[i] / 1000) * sampleRate))
                st.release = exp(-1 / (max(0.0001, v.releaseMs[i] / 1000) * sampleRate))
                st.gain = GainMath.linear(fromDB: min(40, max(-40, v.gainDB[i].isNaN ? 0 : v.gainDB[i])))
                return st
            }
            b0 = make(0); b1 = make(1); b2 = make(2); b3 = make(3)
        }

        fileprivate func band(_ i: Int) -> BandState {
            switch i { case 0: b0; case 1: b1; case 2: b2; default: b3 }
        }
    }

    private var active = false
    private var x1 = Crossover(), x2 = Crossover(), x3 = Crossover()
    private var preGain = 1.0, makeup = 1.0
    private var filters: [ChannelFilters]
    private var bands: [BandState]
    /// Current (fading) solo / bypass mixes and their targets; see `Config.audible`.
    private var audible = SIMD4<Double>(repeating: 1), bypass = SIMD4<Double>(repeating: 0)
    private var audibleTarget = SIMD4<Double>(repeating: 1), bypassTarget = SIMD4<Double>(repeating: 0)
    private var fadeCoef = 0.0
    /// Largest band input peak (linear, after the split) since `takeMeterPeak()`: the per-band input meter.
    private(set) var meterPeak = SIMD4<Double>(repeating: 0)

    init(settings: MultibandCompressorSettings, sampleRate: Double, channels: Int) {
        filters = Array(repeating: ChannelFilters(), count: max(1, channels))
        bands = Array(repeating: BandState(), count: 4)
        apply(Config(settings: settings, sampleRate: sampleRate), keepingState: false)
    }

    /// Installs new settings. With `keepingState` the filter memories and the detector/gain-reduction
    /// state survive (no click when a preset is tweaked). Allocation-free.
    mutating func apply(_ c: Config, keepingState: Bool = true) {
        active = c.active
        x1 = c.x1; x2 = c.x2; x3 = c.x3
        preGain = c.preGain; makeup = c.makeup
        for i in 0..<4 {
            var n = c.band(i)
            if keepingState { n.env = bands[i].env; n.gr = bands[i].gr }
            bands[i] = n
        }
        audibleTarget = c.audible; bypassTarget = c.bypass; fadeCoef = c.fadeCoef
        if !keepingState { audible = c.audible; bypass = c.bypass }
    }

    /// The band input peak since the last call, then starts a new one. Allocation-free.
    mutating func takeMeterPeak() -> SIMD4<Double> {
        let p = meterPeak; meterPeak = .zero; return p
    }

    /// Smoothed gain reduction per band in dB (>= 0), as the detector has it now.
    var gainReductionDB: SIMD4<Double> { SIMD4(bands[0].gr, bands[1].gr, bands[2].gr, bands[3].gr) }
    /// Bypass mix per band right now (1 = fully bypassed).
    var bypassMix: SIMD4<Double> { bypass }

    /// Output makeup and band gains (dB) without touching anything else: the chain ramps them per sub-block. Allocation-free.
    mutating func setGains(makeupDB: Double, bandDB: SIMD4<Double>) {
        makeup = GainMath.linear(fromDB: makeupDB)
        for i in 0..<4 { bands[i].gain = GainMath.linear(fromDB: min(40, max(-40, bandDB[i].isNaN ? 0 : bandDB[i]))) }
    }

    /// Clears filter memories and detector state. Allocation-free.
    mutating func reset() {
        for c in 0..<filters.count { filters[c] = ChannelFilters() }
        for i in 0..<4 { bands[i].env = 0; bands[i].gr = 0 }
        audible = audibleTarget; bypass = bypassTarget; meterPeak = .zero
    }

    mutating func process(_ buf: inout [[Float]]) {
        guard active, let n = buf.first?.count, n > 0 else { return }
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: buf.count)
        defer { ptrs.deallocate() }
        for c in 0..<buf.count {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(from: buf[c], count: n)
            (ptrs + c).initialize(to: p)
        }
        process(channels: ptrs, channelCount: buf.count, frames: n)
        for c in 0..<buf.count {
            buf[c] = Array(UnsafeBufferPointer(start: ptrs[c], count: n))
            ptrs[c].deallocate()
        }
    }

    /// Allocation-free core (realtime path): in place on deinterleaved channel pointers. The arithmetic and its order are exactly
    /// the sample-by-sample original (golden-tested bit for bit); only the storage differs: filter memories behind one pointer
    /// (no uniqueness/bounds checks per access), band detector states and the per-channel band split in locals.
    mutating func process(channels buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frames n: Int) {
        guard active, n > 0 else { return }
        let chans = min(channelCount, filters.count)
        let x1 = self.x1, x2 = self.x2, x3 = self.x3, preGain = self.preGain, makeup = self.makeup
        var bs0 = bands[0], bs1 = bands[1], bs2 = bands[2], bs3 = bands[3]
        // Solo / bypass only touch the arithmetic while one is set or still fading: the default path stays bit-identical.
        let aT = audibleTarget, bT = bypassTarget, k = fadeCoef
        var au = audible, by = bypass
        let mixing = au != SIMD4(repeating: 1) || by != .zero || aT != au || bT != by
        var meter = meterPeak
        filters.withUnsafeMutableBufferPointer { fp in
            withUnsafeTemporaryAllocation(of: SIMD4<Double>.self, capacity: max(1, chans)) { sc in
                for i in 0..<n {
                    for c in 0..<chans {
                        let x = Double(buf[c][i]) * preGain
                        let a = fp[c].s1.run(x, x1)
                        let b = fp[c].s2.run(a.hi, x2)
                        let d = fp[c].s3.run(b.hi, x3)
                        let b0 = fp[c].apLow3.allpass(fp[c].apLow2.allpass(a.lo, x2), x3)
                        let b1 = fp[c].apMid3.allpass(b.lo, x3)
                        sc[c] = SIMD4(b0, b1, d.lo, d.hi)
                    }
                    var pk = SIMD4<Double>(repeating: 0)
                    for c in 0..<chans {
                        pk[0] = max(pk[0], abs(sc[c][0])); pk[1] = max(pk[1], abs(sc[c][1]))
                        pk[2] = max(pk[2], abs(sc[c][2])); pk[3] = max(pk[3], abs(sc[c][3]))
                    }
                    meter = pointwiseMax(meter, pk)
                    var g = SIMD4<Double>(bs0.step(peak: pk[0]), bs1.step(peak: pk[1]), bs2.step(peak: pk[2]), bs3.step(peak: pk[3]))
                    if mixing {
                        au = aT + (au - aT) * k; by = bT + (by - bT) * k
                        g = (g * (1 - by) + by) * au
                    }
                    for c in 0..<chans {
                        let y = (sc[c] * g).sum() * makeup
                        buf[c][i] = Float(y)
                    }
                }
            }
        }
        bands[0] = bs0; bands[1] = bs1; bands[2] = bs2; bands[3] = bs3
        meterPeak = meter
        if mixing {
            // Snap once within 1e-6 of the target (-120 dB): from then on the plain path runs again.
            for i in 0..<4 {
                if abs(au[i] - aT[i]) < 1e-6 { au[i] = aT[i] }
                if abs(by[i] - bT[i]) < 1e-6 { by[i] = bT[i] }
            }
            audible = au; bypass = by
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
