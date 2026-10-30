import Foundation
import SQCore

/// Split-band de-esser: a band-pass detector at the sibilance region drives gain reduction of the content above `splitHz`.
/// The trigger is relative (sibilance level against broadband level), so it needs no absolute threshold and works before
/// loudness normalization. Zero latency, state kept across `process` calls.
public struct DeEsser: Sendable {
    public var sampleRate: Int
    /// Sibilance/broadband envelope ratio above which reduction starts (0.35 = sibilance 9 dB under broadband).
    public var ratioThreshold: Double
    /// Maximum reduction as linear gain of the high band.
    public var minGain: Double
    /// Everything one channel keeps between samples (one array: one pointer in the hot loop).
    private struct Chan {
        var detector: Biquad, splitter: Biquad, splitter2: Biquad, lowpass: Biquad, lowpass2: Biquad
        var envSib = 0.0, envAll = 0.0
        /// Narrow range only: the upper edge of the reduced band.
        var bandTop = Biquad()
    }
    private var chan: [Chan]
    private var gain = 1.0
    private var atk: Double, rel: Double
    private let envCoef: Double
    /// Narrow: only the band between the split and 1.3 x the center is reduced (`x - (1 - gain) x band`). Wide / All HF reduce
    /// everything above the split (the original path, bit for bit).
    private var narrow = false
    /// Output only what is being removed (`(1 - gain) x band`), for tuning.
    public var listen = false

    public init(sampleRate: Int, channelCount: Int, centerHz: Double = 7000, splitHz: Double = 5000,
                ratioThreshold: Double = 0.35, maxReductionDB: Double = 10) {
        self.sampleRate = sampleRate
        self.ratioThreshold = ratioThreshold
        minGain = GainMath.linear(fromDB: -abs(maxReductionDB))
        let fs = Double(sampleRate)
        let f = Self.filters(centerHz: centerHz, splitHz: splitHz, fs: fs)
        chan = Array(repeating: Chan(detector: f.bp, splitter: f.hp, splitter2: f.hp, lowpass: f.lp, lowpass2: f.lp), count: channelCount)
        atk = exp(-1 / (fs * 0.001)); rel = exp(-1 / (fs * 0.04)); envCoef = exp(-1 / (fs * 0.005))
    }

    /// RBJ band-pass (constant 0 dB peak) and 2nd-order Butterworth high/low-pass pair, cascaded twice (Linkwitz-Riley 4th order: low + high sum is flat in level).
    private static func filters(centerHz: Double, splitHz: Double, fs: Double) -> (bp: Biquad, hp: Biquad, lp: Biquad) {
        let w0 = 2 * Double.pi * min(centerHz, fs * 0.45) / fs
        let q = 1.0, al = sin(w0) / (2 * q), a0 = 1 + al
        let bp = Biquad(b0: al / a0, b1: 0, b2: -al / a0, a1: -2 * cos(w0) / a0, a2: (1 - al) / a0)
        let h0 = 2 * Double.pi * min(splitHz, fs * 0.45) / fs
        let hq = 0.7071, ha = sin(h0) / (2 * hq), hn = 1 + ha, c = cos(h0)
        let hp = Biquad(b0: (1 + c) / 2 / hn, b1: -(1 + c) / hn, b2: (1 + c) / 2 / hn, a1: -2 * c / hn, a2: (1 - ha) / hn)
        let lp = Biquad(b0: (1 - c) / 2 / hn, b1: (1 - c) / hn, b2: (1 - c) / 2 / hn, a1: -2 * c / hn, a2: (1 - ha) / hn)
        return (bp, hp, lp)
    }

    /// Where the de-esser listens and what it reduces, keeping all filter state (safe while playing). `range` 0 Narrow (a band
    /// around the center), 1 Wide (from 5/7 of the center up: 5 kHz at 7 kHz, the original), 2 All HF (from 0.4 x the center up).
    public mutating func configure(centerHz: Double, range: Int) {
        let fs = Double(sampleRate)
        let split = range == 0 ? centerHz * 0.8 : range == 2 ? centerHz * 0.4 : centerHz * 5 / 7
        let f = Self.filters(centerHz: centerHz, splitHz: split, fs: fs)
        let top = Self.filters(centerHz: centerHz, splitHz: centerHz * 1.3, fs: fs).lp
        narrow = range == 0
        for c in 0..<chan.count {
            Self.setCoefficients(&chan[c].detector, f.bp); Self.setCoefficients(&chan[c].splitter, f.hp); Self.setCoefficients(&chan[c].splitter2, f.hp)
            Self.setCoefficients(&chan[c].lowpass, f.lp); Self.setCoefficients(&chan[c].lowpass2, f.lp); Self.setCoefficients(&chan[c].bandTop, top)
        }
    }

    private static func setCoefficients(_ b: inout Biquad, _ c: Biquad) { b.b0 = c.b0; b.b1 = c.b1; b.b2 = c.b2; b.a1 = c.a1; b.a2 = c.a2 }

    /// Reaction speed: 0 Fast (0.5 ms / 20 ms), 1 Medium (1 ms / 40 ms, the original), 2 Slow (2 ms / 100 ms). Times are ours (unsourced).
    public mutating func setSpeed(_ speed: Int) {
        let fs = Double(sampleRate)
        let (a, r): (Double, Double) = speed == 0 ? (0.0005, 0.02) : speed == 2 ? (0.002, 0.1) : (0.001, 0.04)
        atk = exp(-1 / (fs * a)); rel = exp(-1 / (fs * r))
    }

    /// Forgets all filter, envelope and gain state (use on a seek).
    public mutating func reset() {
        for c in 0..<chan.count {
            chan[c].detector.reset(); chan[c].splitter.reset(); chan[c].splitter2.reset(); chan[c].lowpass.reset(); chan[c].lowpass2.reset()
            chan[c].envSib = 0; chan[c].envAll = 0; chan[c].bandTop.reset()
        }
        gain = 1
    }

    public mutating func process(_ buf: inout [[Float]]) {
        let n = buf.first?.count ?? 0
        let chs = buf.count
        guard n > 0, chs > 0 else { return }
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: chs)
        for c in 0..<chs {
            ptrs[c] = .allocate(capacity: n)
            ptrs[c].update(from: buf[c], count: n)
        }
        process(ptrs, channelCount: chs, frames: n)
        for c in 0..<chs {
            buf[c] = Array(UnsafeBufferPointer(start: ptrs[c], count: n))
            ptrs[c].deallocate()
        }
        ptrs.deallocate()
    }

    /// In place on channel pointers; does not allocate (the realtime path). `channelCount` must not exceed the init's.
    public mutating func process(_ buf: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channelCount chs: Int, frames n: Int) {
        let chs = min(chs, chan.count)
        let envCoef = self.envCoef, ratioThreshold = self.ratioThreshold, minGain = self.minGain, atk = self.atk, rel = self.rel
        var gain = self.gain
        let narrow = self.narrow, listen = self.listen
        // Same arithmetic and order as the per-array original (golden-tested bit for bit); one pointer, no per-access checks.
        chan.withUnsafeMutableBufferPointer { cp in
            withUnsafeTemporaryAllocation(of: Double.self, capacity: max(1, 2 * chs)) { tmp in
                let hi = tmp.baseAddress!, lo = hi + chs
                for i in 0..<n {
                    var sib = 0.0, all = 0.0
                    for c in 0..<chs {
                        let x = Double(buf[c][i])
                        hi[c] = cp[c].splitter2.process(cp[c].splitter.process(x))
                        lo[c] = cp[c].lowpass2.process(cp[c].lowpass.process(x))
                        let s = abs(cp[c].detector.process(x))
                        cp[c].envSib = max(s, cp[c].envSib * envCoef + s * (1 - envCoef))
                        let a = abs(x)
                        cp[c].envAll = max(a, cp[c].envAll * envCoef + a * (1 - envCoef))
                        sib = max(sib, cp[c].envSib); all = max(all, cp[c].envAll)
                    }
                    var target = 1.0
                    if all > 1e-6, sib > ratioThreshold * all { target = max(minGain, ratioThreshold * all / sib) }
                    let k = target < gain ? atk : rel
                    gain = target + (gain - target) * k
                    if narrow || listen {
                        for c in 0..<chs {
                            // Narrow cuts only the band (hi up to 1.3 x center); Wide / All HF cut everything above the split.
                            let band = narrow ? cp[c].bandTop.process(hi[c]) : hi[c]
                            let removed = (1 - gain) * band
                            buf[c][i] = listen ? Float(removed) : Float(Double(buf[c][i]) - removed)
                        }
                    } else {
                        for c in 0..<chs { buf[c][i] = Float(lo[c] + gain * hi[c]) }
                    }
                }
            }
        }
        self.gain = gain
    }
}

/// Offline role chain for a track: Voice (dialogue) = mono to stereo, noise reduction + EQ + compressor (the role preset incl. de-esser), loudness to -14 LUFS, true-peak limiter at -1 dBTP. Music and SFX = mono to stereo, role voicing, loudness to
/// -20 LUFS (`AudioTag.targetLUFS`, i.e. 6 dB under the voice), same limiter. The loudness stage lands within a few tenths of
/// a LU; the limiter's ceiling is tightened until the measured 4x true peak is at or under the target.
public enum RoleChain {
    public static let truePeakCeilingDB = -1.0

    /// iPhone/phone clips are mono: duplicate to stereo so the track pans and meters like the rest. Other counts pass through.
    public static func monoToStereo(_ x: [[Float]]) -> [[Float]] { x.count == 1 ? [x[0], x[0]] : x }

    public static func render(_ input: [[Float]], role: AudioTag, sampleRate: Int,
                              truePeakCeilingDB: Double = truePeakCeilingDB) throws -> [[Float]] {
        let n = input.first?.count ?? 0
        guard n > 0 else { return monoToStereo(input) }
        var x = monoToStereo(input)
        var fx = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: .forRole(role),
                                    sampleRate: sampleRate, channelCount: x.count)
        x = fx.render(x, start: .zero).channels
        return finish(x, targetLUFS: role.targetLUFS, sampleRate: sampleRate, ceilingDB: truePeakCeilingDB)
    }

    /// Maximum boost the loudness stage may apply.
    public static let maxBoostDB = 24.0

    /// Loudness gain to the target (boost capped at `maxBoostDB`), then the limiter; up to 6 passes with corrected gain /
    /// ceiling. Returns the candidate with the true peak at or under `ceilingDB` that is closest to the target. If no pass
    /// gets under the ceiling, the last one is trimmed by exactly its overshoot (gain is linear in true peak), so the result
    /// never exceeds the ceiling. Clips without a gated loudness (< 400 ms or below -70 LUFS) get the limiter only; true
    /// silence is returned unchanged. Any channel count: channels are limited in linked pairs (an odd last one alone).
    static func finish(_ x: [[Float]], targetLUFS: Double, sampleRate: Int, ceilingDB: Double) -> [[Float]] {
        let m0 = measure(x, sampleRate: sampleRate)
        guard m0.truePeakDB > -120 else { return x }
        var gainDB = m0.lufs.isFinite ? min(maxBoostDB, targetLUFS - m0.lufs) : 0
        let canTune = m0.lufs.isFinite
        var ceiling = ceilingDB
        var best: (y: [[Float]], err: Double)?
        var last = x, lastOver = 0.0
        for _ in 0..<6 {
            let y = limited(x, gainDB: gainDB, sampleRate: sampleRate, ceilingDB: ceiling)
            let m = measure(y, sampleRate: sampleRate)
            let over = m.truePeakDB - ceilingDB
            let err = canTune ? targetLUFS - m.lufs : 0
            last = y; lastOver = over
            if over <= 0, best == nil || abs(err) < abs(best!.err) { best = (y, err) }
            if over <= 0, abs(err) <= 0.3 || !canTune { break }
            if over > 0 { ceiling -= over + 0.05 }
            if canTune, abs(err) > 0.3, err.isFinite { gainDB = min(maxBoostDB, gainDB + err) }
        }
        if let best { return best.y }
        let trim = Float(GainMath.linear(fromDB: -(lastOver + 0.01)))
        return last.map { $0.map { $0 * trim } }
    }

    private static func limited(_ x: [[Float]], gainDB: Double, sampleRate: Int, ceilingDB: Double) -> [[Float]] {
        var y = x
        let g = Float(GainMath.linear(fromDB: gainDB))
        for c in 0..<y.count { for i in 0..<y[c].count { y[c][i] *= g } }
        var c = 0
        while c < y.count {
            var lim = MasterLimiter(sampleRate: sampleRate, ceilingDB: ceilingDB)
            var l = y[c], r = c + 1 < y.count ? y[c + 1] : y[c]
            let n = l.count
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    lim.process(left: lp.baseAddress!, right: rp.baseAddress!, count: n)
                }
            }
            y[c] = l
            if c + 1 < y.count { y[c + 1] = r }
            c += 2
        }
        return y
    }

    public static func measure(_ x: [[Float]], sampleRate: Int) -> (lufs: Double, truePeakDB: Double) {
        var m = LoudnessMeter(sampleRate: sampleRate, channelCount: x.count)
        m.process(x)
        return (m.integrated, m.truePeakDB.max() ?? -.infinity)
    }
}
