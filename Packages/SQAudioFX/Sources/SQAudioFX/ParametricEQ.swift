import Foundation
import SQCore

/// RBJ biquad coefficients for the 5-band Parametric EQ (HP, low shelf, 5 peaks, high shelf, LP). Pure functions, shared by
/// the chain stage and the tests (magnitude response).
enum PEQBiquad {
    struct Coef: Equatable { var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0 }
    struct Mem { var z1 = 0.0, z2 = 0.0 }

    static func clampHz(_ hz: Double, _ fs: Double) -> Double { min(max(hz.isNaN ? 1_000 : hz, 10), fs * 0.45) }

    static func peak(hz: Double, gainDB: Double, q: Double, fs: Double) -> Coef {
        let a = pow(10, gainDB / 40), w = 2 * Double.pi * clampHz(hz, fs) / fs
        let alpha = sin(w) / (2 * max(q, 0.05)), cw = cos(w)
        let a0 = 1 + alpha / a
        return Coef(b0: (1 + alpha * a) / a0, b1: -2 * cw / a0, b2: (1 - alpha * a) / a0, a1: -2 * cw / a0, a2: (1 - alpha / a) / a0)
    }

    /// RBJ shelf with Q (Q = 0.7071 is slope 1).
    static func shelf(low: Bool, hz: Double, gainDB: Double, q: Double, fs: Double) -> Coef {
        let a = pow(10, gainDB / 40), w = 2 * Double.pi * clampHz(hz, fs) / fs
        let cw = cos(w), alpha = sin(w) / (2 * max(q, 0.05)), sa = 2 * a.squareRoot() * alpha
        let b0, b1, b2, a0, a1, a2: Double
        if low {
            b0 = a * ((a + 1) - (a - 1) * cw + sa); b1 = 2 * a * ((a - 1) - (a + 1) * cw); b2 = a * ((a + 1) - (a - 1) * cw - sa)
            a0 = (a + 1) + (a - 1) * cw + sa; a1 = -2 * ((a - 1) + (a + 1) * cw); a2 = (a + 1) + (a - 1) * cw - sa
        } else {
            b0 = a * ((a + 1) + (a - 1) * cw + sa); b1 = -2 * a * ((a - 1) + (a + 1) * cw); b2 = a * ((a + 1) + (a - 1) * cw - sa)
            a0 = (a + 1) - (a - 1) * cw + sa; a1 = 2 * ((a - 1) - (a + 1) * cw); a2 = (a + 1) - (a - 1) * cw - sa
        }
        return Coef(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// 2nd-order Butterworth high-pass (12 dB/oct) or low-pass.
    static func cut(high: Bool, hz: Double, fs: Double) -> Coef {
        let w = 2 * Double.pi * clampHz(hz, fs) / fs
        let cw = cos(w), alpha = sin(w) / (2 * 0.5.squareRoot()), a0 = 1 + alpha
        let a1 = -2 * cw / a0, a2 = (1 - alpha) / a0
        return high ? Coef(b0: (1 + cw) / 2 / a0, b1: -(1 + cw) / a0, b2: (1 + cw) / 2 / a0, a1: a1, a2: a2)
                    : Coef(b0: (1 - cw) / 2 / a0, b1: (1 - cw) / a0, b2: (1 - cw) / 2 / a0, a1: a1, a2: a2)
    }

    static func coef(filter i: Int, _ b: AudioPEQBand, fs: Double) -> Coef {
        switch i {
        case 0: cut(high: true, hz: b.hz, fs: fs)
        case 1: shelf(low: true, hz: b.hz, gainDB: b.gainDB, q: b.q, fs: fs)
        case 7: shelf(low: false, hz: b.hz, gainDB: b.gainDB, q: b.q, fs: fs)
        case 8: cut(high: false, hz: b.hz, fs: fs)
        default: peak(hz: b.hz, gainDB: b.gainDB, q: b.q, fs: fs)
        }
    }

    /// |H| in dB at `hz`.
    static func magnitudeDB(_ c: Coef, hz: Double, fs: Double) -> Double {
        let w = 2 * Double.pi * hz / fs
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = c.b0 + c.b1 * c1 + c.b2 * c2, ni = -(c.b1 * s1 + c.b2 * s2)
        let dr = 1 + c.a1 * c1 + c.a2 * c2, di = -(c.a1 * s1 + c.a2 * s2)
        return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }

    /// Combined response of every enabled filter of `v` at `hz`.
    static func totalMagnitudeDB(_ v: AudioParametricEQValues, hz: Double, fs: Double) -> Double {
        var sum = 0.0
        for i in 0..<AudioParametricEQValues.bandCount where v[i].on {
            sum += magnitudeDB(coef(filter: i, v[i], fs: fs), hz: hz, fs: fs)
        }
        return sum
    }
}

/// The 5-band Parametric EQ stage of a clip chain. Coefficients follow the values (ramped every `rampChunk` samples), filter
/// memory stays; a filter that is off is skipped and its memory cleared.
final class ParametricEQStage {
    private static let n = AudioParametricEQValues.bandCount
    private var coefs = [PEQBiquad.Coef](repeating: PEQBiquad.Coef(), count: n)
    private let mem: UnsafeMutablePointer<PEQBiquad.Mem>
    private let channels: Int
    private var values: AudioParametricEQValues?
    var wasOff = false

    init(channels: Int) {
        self.channels = channels
        mem = .allocate(capacity: channels * Self.n)
        mem.initialize(repeating: PEQBiquad.Mem(), count: channels * Self.n)
    }
    deinit { mem.deallocate() }
    func reset() { mem.update(repeating: PEQBiquad.Mem(), count: channels * Self.n) }

    private func set(_ v: AudioParametricEQValues, fs: Double) {
        guard values != v else { return }
        for i in 0..<Self.n {
            if let old = values, old[i] == v[i] { continue }
            coefs[i] = PEQBiquad.coef(filter: i, v[i], fs: fs)
        }
        values = v
    }

    /// A band switching off fades its gain to 0 dB across the block (then it is dropped); one switching on fades in from 0 dB.
    /// `tEnd` = position of the chunk's end, so the fade is complete when the block ends.
    private static func lerp(_ a: AudioPEQBand, _ b: AudioPEQBand, _ t: Double, _ tEnd: Double) -> AudioPEQBand {
        var r = AudioPEQBand(on: b.on, hz: a.hz + (b.hz - a.hz) * t, gainDB: a.gainDB + (b.gainDB - a.gainDB) * t, q: a.q + (b.q - a.q) * t)
        if a.on && !b.on { r.on = true; r.hz = a.hz; r.q = a.q; r.gainDB = a.gainDB * (1 - tEnd) }
        else if !a.on && b.on { r.gainDB = b.gainDB * tEnd }
        return r
    }

    /// Values `v0` at the first sample moving linearly towards `v1` one block later.
    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                 from v0: AudioParametricEQValues, to v1: AudioParametricEQValues, sampleRate fs: Double) {
        if wasOff { reset(); wasOff = false }
        if v0 == v1 { set(v0, fs: fs); run(buf, chs, 0, n); return }
        var s = 0
        while s < n {
            let k = min(ClipAudioFXChain.rampChunk, n - s)
            let t = Double(s) / Double(n), te = Double(s + k) / Double(n)
            func l(_ a: AudioPEQBand, _ b: AudioPEQBand) -> AudioPEQBand { Self.lerp(a, b, t, te) }
            set(AudioParametricEQValues(hp: l(v0.hp, v1.hp), lowShelf: l(v0.lowShelf, v1.lowShelf), b1: l(v0.b1, v1.b1),
                                        b2: l(v0.b2, v1.b2), b3: l(v0.b3, v1.b3), b4: l(v0.b4, v1.b4), b5: l(v0.b5, v1.b5),
                                        highShelf: l(v0.highShelf, v1.highShelf), lp: l(v0.lp, v1.lp)), fs: fs)
            run(buf, chs, s, k)
            s += k
        }
    }

    private func run(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, _ chs: Int, _ from: Int, _ n: Int) {
        guard let v = values else { return }
        for c in 0..<min(chs, channels) {
            let p = buf[c] + from
            for k in 0..<Self.n {
                let band = v[k]
                if !band.on { mem[c * Self.n + k] = PEQBiquad.Mem(); continue }
                // A shelf or peak at 0 dB is the identity: skipped once its memory is empty (never cut while it still rings).
                var m = mem[c * Self.n + k]
                let flat = k >= 1 && k <= 7 && band.gainDB == 0
                if flat && m.z1 == 0 && m.z2 == 0 { continue }
                let q = coefs[k]
                for i in 0..<n {
                    let x = Double(p[i])
                    let y = q.b0 * x + m.z1
                    m.z1 = q.b1 * x - q.a1 * y + m.z2
                    m.z2 = q.b2 * x - q.a2 * y
                    p[i] = Float(y)
                }
                if flat && abs(m.z1) < 1e-9 && abs(m.z2) < 1e-9 { m = PEQBiquad.Mem() }
                mem[c * Self.n + k] = m
            }
        }
    }
}

/// The Multiband Compressor clip stage: `MultibandCompressor` (4 bands, LR4 crossovers) fed from the clip effect's values,
/// then the output limiter (`LookaheadLimiter`). Output gain and band gains ramp from the block-start to the block-end value
/// every `rampChunk` samples; thresholds, ratios, times and crossovers apply from the block start (the Config is rebuilt only
/// when they change). Allocation-free.
///
/// Latency: `latency` samples (the limiter's look-ahead), always, also with the limiter off or the effect disabled, so the
/// chain's latency depends on the layout only.
final class MultibandStage {
    static let lookaheadMs = 5.0
    /// Fixed latency of every multiband slot at 48 kHz (240 samples).
    static let latency = Int((Double(ClipAudioFXChain.sampleRate) * lookaheadMs / 1000).rounded())

    private var comp: MultibandCompressor
    private var settled: AudioMultibandValues?       // last values the Config was built from (gains zeroed)
    private let sampleRate: Double
    private let ptrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let channels: Int
    /// Output limiter (Premiere's Multiband Limiter): `limiterGainDB` in front, then a look-ahead brickwall at the margin.
    private let limiter: LookaheadLimiter
    var wasOff = false
    /// The clip effect's id, split for `MultibandMeterTap` (one atomic compare per block decides whether to publish).
    private let idHi: UInt64, idLo: UInt64
    private let meters: MultibandMeterTap

    init(sampleRate: Double, channels: Int, maxFrames: Int = 4096, id: UUID = UUID(), meters: MultibandMeterTap = .shared) {
        self.sampleRate = sampleRate
        self.channels = channels
        (idHi, idLo) = MultibandMeterTap.split(id)
        self.meters = meters
        comp = MultibandCompressor(settings: .neutral, sampleRate: sampleRate, channels: channels)
        ptrs = .allocate(capacity: max(1, channels))
        limiter = LookaheadLimiter(sampleRate: sampleRate, channels: channels, lookaheadMs: Self.lookaheadMs)
    }
    deinit { ptrs.deallocate() }
    func reset() { comp.reset(); limiter.reset() }

    static func settings(_ v: AudioMultibandValues) -> MultibandCompressorSettings {
        MultibandCompressorSettings(
            bypass: false, crossoversHz: [v.crossoverHz[0], v.crossoverHz[1], v.crossoverHz[2]],
            bands: (0..<4).map { MultibandCompressorSettings.Band(thresholdDB: v.thresholdDB[$0], ratio: v.ratio[$0],
                                                                  attackMs: v.attackMs[$0], releaseMs: v.releaseMs[$0], gainDB: v.gainDB[$0]) },
            preGainDB: 0, makeupGainDB: v.outputGainDB)
    }

    /// The effect is switched off: the sound passes unchanged, still delayed by `latency`.
    func bypass(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int) {
        wasOff = true
        limiter.delayOnly(buf, channels: min(chs, channels), frames: n)
    }

    func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels chs: Int, frames n: Int,
                 from v0: AudioMultibandValues, to v1: AudioMultibandValues) {
        if wasOff { comp.reset(); wasOff = false }
        var key = v0
        key.outputGainDB = 0; key.gainDB = .zero
        if settled != key {
            comp.apply(MultibandCompressor.Config(values: v0, sampleRate: sampleRate))
            settled = key
        }
        let ramped = v0.outputGainDB != v1.outputGainDB || v0.gainDB != v1.gainDB
        if !ramped { comp.setGains(makeupDB: v0.outputGainDB, bandDB: v0.gainDB) }
        let c = min(chs, channels)
        var s = 0
        while s < n {
            let k = ramped ? min(ClipAudioFXChain.rampChunk, n - s) : n
            if ramped {
                let t = Double(s) / Double(n)
                comp.setGains(makeupDB: v0.outputGainDB + (v1.outputGainDB - v0.outputGainDB) * t,
                              bandDB: v0.gainDB + (v1.gainDB - v0.gainDB) * t)
            }
            for ch in 0..<c { ptrs[ch] = buf[ch] + s }
            comp.process(channels: ptrs, channelCount: c, frames: k)
            s += k
        }
        if v0.limiterOn {
            let g1 = v1.limiterOn ? v1.limiterGainDB : v0.limiterGainDB
            ClipAudioFXChain.ramp(buf, channels: c, frames: n, fromDB: v0.limiterGainDB, toDB: g1)
            let margin = min(0, max(-18, v0.limiterMarginDB.isNaN ? -0.1 : v0.limiterMarginDB))
            let release = min(5_000, max(5, v0.limiterReleaseMs.isNaN ? 500 : v0.limiterReleaseMs))
            let attack = min(500, max(0, v0.limiterAttackMs.isNaN ? 0 : v0.limiterAttackMs))
            limiter.configure(ceilingDB: margin, releaseMs: release, attackMs: attack)
        }
        // Safety: never NaN / inf out of this stage (one would poison every filter after it for good).
        for ch in 0..<c {
            let p = buf[ch]
            for i in 0..<n where !p[i].isFinite { p[i] = 0 }
        }
        limiter.process(buf, channels: c, frames: n, active: v0.limiterOn)
        let peak = comp.takeMeterPeak()
        if meters.isWatched(hi: idHi, lo: idLo) {
            // Applied reduction: a bypassed band reduces nothing (its detector keeps running for a smooth return).
            let gr = comp.gainReductionDB * (1 - comp.bypassMix)
            meters.publish(inputPeak: peak, gainReductionDB: gr, limiterReductionDB: v0.limiterOn ? -limiter.gainReductionDB : 0)
        }
    }
}
