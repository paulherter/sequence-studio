import Foundation
import Testing
import SQCore
@testable import SQAudioFX

// Gain staging and distortion of the maintainer's imported Premiere "Broadcast" multiband preset through the real clip chain
// (`ClipAudioFXChain`, the same code playback and export run). Bug: the re-imported project sounded completely clipped.

enum BroadcastHarness {
    /// The maintainer's Broadcast panel: crossovers 137/1147/6910 Hz; thresholds -15/-11/-17/-15 dB, gains +4/-2/-4/-2 dB,
    /// ratios 3/2/2/3, attack 1 ms, release 100 ms, output 0; limiter threshold -9, margin -0.1, attack 4, release 500.
    static func broadcast(limiter: Bool = true) -> AudioMultibandValues {
        AudioMultibandValues(outputGainDB: 0, crossoverHz: SIMD3(137, 1147, 6910), thresholdDB: SIMD4(-15, -11, -17, -15),
                             ratio: SIMD4(3, 2, 2, 3), attackMs: SIMD4(repeating: 1), releaseMs: SIMD4(repeating: 100),
                             gainDB: SIMD4(4, -2, -4, -2), limiterOn: limiter, limiterThresholdDB: -9, limiterMarginDB: -0.1,
                             limiterReleaseMs: 500, limiterAttackMs: 4)
    }

    static func neutral(_ xo: SIMD3<Double> = SIMD3(137, 1147, 6910)) -> AudioMultibandValues {
        AudioMultibandValues(outputGainDB: 0, crossoverHz: xo, thresholdDB: SIMD4(repeating: 0), ratio: SIMD4(repeating: 1),
                             attackMs: SIMD4(repeating: 1), releaseMs: SIMD4(repeating: 100), gainDB: .zero)
    }

    /// Runs `x` (stereo) through a one-slot multiband chain in blocks of `block`.
    static func run(_ v: AudioMultibandValues, _ x: [[Float]], block: Int = 512) throws -> [[Float]] {
        let l = [AudioFXSlot(id: UUID(), kind: ClipEffect.audioMultibandKind)]
        let chain = try ClipAudioFXChain(layout: l, channelCount: x.count, maxFrames: block)
        let steps = [AudioFXStep(id: l[0].id, enabled: true, stage: .multiband(v))]
        var out: [[[Float]]] = []
        for part in Sig.chunked(x, sizes: [block]) { var b = part; chain.process(&b, steps: steps); out.append(b) }
        return Sig.concat(out, channels: x.count)
    }

    /// Integrated loudness (LUFS, BS.1770 gated).
    static func lufs(_ x: [[Float]]) -> Double {
        var m = LoudnessMeter(sampleRate: 48000, channelCount: x.count)
        m.process(x)
        return m.integrated
    }

    /// Speech-like stereo signal scaled to `targetLUFS`: glottal pulse train through three formants, syllable envelope,
    /// pitch drift, unvoiced noise bursts (sibilants) and pauses. Crest factor like real voice (peaks ~12-15 dB over RMS).
    static func speech(seconds: Double, targetLUFS: Double = -18) -> [[Float]] {
        let fs = 48000.0, n = Int(seconds * fs)
        let noise = Sig.noise(amplitude: 1, count: n, seed: 11)
        var y = [Float](repeating: 0, count: n)
        // Formant resonators (2-pole), re-tuned per syllable.
        struct Res { var y1 = 0.0, y2 = 0.0 }
        var r = [Res(), Res(), Res()]
        let vowels: [[Double]] = [[730, 1090, 2440], [270, 2290, 3010], [530, 1840, 2480], [570, 840, 2410], [300, 870, 2240]]
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / fs
            let syl = Int(t * 4)                                   // 4 syllables per second
            let inSyl = t * 4 - Double(syl)
            let pause = syl % 9 == 8                               // a breath every ~2 s
            let env = pause ? 0 : pow(sin(.pi * inSyl), 0.6) * (0.6 + 0.4 * sin(Double(syl) * 1.7))
            let f0 = 120 + 25 * sin(2 * .pi * 0.5 * t) + 10 * sin(Double(syl))
            phase += f0 / fs
            var src = 0.0
            if phase >= 1 { phase -= 1; src = 1 }                  // glottal impulse
            let sibilant = syl % 5 == 2 && inSyl > 0.6
            let v = vowels[syl % vowels.count]
            var s = 0.0
            for k in 0..<3 {
                let bw = 80.0 + 40 * Double(k), w = 2 * .pi * v[k] / fs, rr = exp(-.pi * bw / fs)
                let o = src * (1 - rr) * 6 + 2 * rr * cos(w) * r[k].y1 - rr * rr * r[k].y2
                r[k].y2 = r[k].y1; r[k].y1 = o
                s += o / Double(k + 1)
            }
            var out = sibilant ? Double(noise[i]) * 0.25 : s * env
            if !sibilant && env == 0 { out = Double(noise[i]) * 0.0005 }
            y[i] = Float(out)
        }
        // High-pass the sibilant noise a little (first difference mix) so it sits up top like an "s".
        var stereo = [y, y]
        let g = Float(pow(10, (targetLUFS - lufs(stereo)) / 20))
        stereo = stereo.map { $0.map { $0 * g } }
        return stereo
    }

    struct Report: CustomStringConvertible {
        var inLUFS = 0.0, outLUFS = 0.0, inPeakDB = 0.0, outPeakDB = 0.0
        var overFS = 0, atCeiling = 0, flatRuns = 0, count = 0
        var description: String {
            String(format: "in %.1f LUFS pk %.2f dB -> out %.1f LUFS pk %.2f dB; >=0dBFS %d, at ceiling %d (%.4f%%), flat runs %d",
                   inLUFS, inPeakDB, outLUFS, outPeakDB, overFS, atCeiling, 100 * Double(atCeiling) / Double(max(1, count)), flatRuns)
        }
    }

    /// Peak, samples at/above 0 dBFS, samples within 0.001 dB of the ceiling, and runs of >= 3 consecutive such samples
    /// (flat tops: hard clipping).
    static func measure(_ x: [[Float]], _ y: [[Float]], ceilingDB: Double = -0.1) -> Report {
        var r = Report()
        r.inLUFS = lufs(x); r.outLUFS = lufs(y)
        let pin = x.flatMap { $0 }.map { abs($0) }.max() ?? 0, pout = y.flatMap { $0 }.map { abs($0) }.max() ?? 0
        r.inPeakDB = Sig.db(Double(pin)); r.outPeakDB = Sig.db(Double(pout))
        let c = Float(pow(10, (ceilingDB - 0.001) / 20))
        for ch in y {
            var run = 0
            for s in ch {
                r.count += 1
                if abs(s) >= 1 { r.overFS += 1 }
                if abs(s) >= c { r.atCeiling += 1; run += 1 } else { if run >= 3 { r.flatRuns += 1 }; run = 0 }
            }
            if run >= 3 { r.flatRuns += 1 }
        }
        return r
    }

    /// Harmonic distortion of a 1 kHz tone through `v`: power of harmonics 2...10 vs the fundamental, in dB (steady state).
    static func thdDB(_ v: AudioMultibandValues, levelDB: Double) throws -> Double {
        let x = Sig.sine(freq: 1000, amplitudeDB: levelDB, seconds: 1.5)
        let y = try run(v, x)
        let tail = y[0][48000..<72000]
        let f = Sig.amplitude(tail, freq: 1000)
        var h = 0.0
        for k in 2...10 { let a = Sig.amplitude(tail, freq: 1000 * Double(k)); h += a * a }
        return 10 * log10(max(h, 1e-30) / (f * f))
    }

    /// Raw interleaved Float32 stereo (48 kHz) from `SQ_MB_MEDIA`, if set: real footage for the diagnostics.
    static func media() -> [[Float]]? {
        guard let p = ProcessInfo.processInfo.environment["SQ_MB_MEDIA"], let d = FileManager.default.contents(atPath: p) else { return nil }
        let f = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = f.count / 2
        return [(0..<n).map { f[2 * $0] }, (0..<n).map { f[2 * $0 + 1] }]
    }
}

@Suite struct BroadcastPresetSafetyTests {
    typealias H = BroadcastHarness

    /// Writes the measurements to `SQ_MB_DIAG` (a file) when set. Not an assertion: the numbers behind the bug report.
    @Test func diagnostics() throws {
        guard let path = ProcessInfo.processInfo.environment["SQ_MB_DIAG"] else { return }
        var lines: [String] = []
        let x = H.speech(seconds: 10)
        lines.append("speech -18 LUFS, limiter on:  " + H.measure(x, try H.run(H.broadcast(), x)).description)
        lines.append("speech -18 LUFS, limiter off: " + H.measure(x, try H.run(H.broadcast(limiter: false), x)).description)
        var inst = H.broadcast(); inst.limiterAttackMs = 0
        lines.append("speech -18 LUFS, limiter attack 0: " + H.measure(x, try H.run(inst, x)).description)
        let hot = H.speech(seconds: 10, targetLUFS: -14)
        lines.append("speech -14 LUFS, limiter on:  " + H.measure(hot, try H.run(H.broadcast(), hot)).description)
        for lv in [-30.0, -20, -12, -6] {
            lines.append(String(format: "THD 1 kHz %.0f dBFS: on %.1f dB, off %.1f dB", lv,
                                try H.thdDB(H.broadcast(), levelDB: lv), try H.thdDB(H.broadcast(limiter: false), levelDB: lv)))
        }
        if let m = H.media() {
            lines.append("media, limiter on:  " + H.measure(m, try H.run(H.broadcast(), m)).description)
            lines.append("media, limiter off: " + H.measure(m, try H.run(H.broadcast(limiter: false), m)).description)
        }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: invariants

    @Test func broadcastSpeechStaysUnderTheCeilingWithoutClipping() throws {
        for lufs in [-18.0, -14] {
            let x = H.speech(seconds: 8, targetLUFS: lufs)
            let y = try H.run(H.broadcast(), x)
            let r = H.measure(x, y)
            #expect(r.outPeakDB <= -0.1 + 1e-4, "\(r)")
            #expect(r.overFS == 0, "\(r)")
            #expect(r.flatRuns == 0, "hard clipping: \(r)")                    // no flat tops at the margin
            #expect(Double(r.atCeiling) / Double(r.count) < 5e-4, "\(r)")   // isolated peaks touch it (old code: 0.4-1 %)
            // Loudness comes from the limiter's drive, not from massive gain: at most the drive (+8.9 dB) plus the band gain.
            #expect(r.outLUFS - r.inLUFS < 10, "\(r)")
        }
    }

    @Test func broadcastToneHasLowDistortion() throws {
        // A steady 1 kHz tone held by the limiter: the gain settles, so the output must stay a clean sine (no waveshaping).
        for level in [-20.0, -12, -6] {
            let thd = try H.thdDB(H.broadcast(), levelDB: level)
            #expect(thd < -40, "THD at \(level) dBFS: \(thd) dB")
        }
    }

    @Test func neutralCrossoversSumFlatAndNullToTheAllpass() throws {
        let xo = SIMD3<Double>(137, 1147, 6910)
        for f in [40.0, 137, 500, 1147, 3000, 6910, 12000] {
            let x = Sig.sine(freq: f, amplitudeDB: -12, seconds: 1)
            let y = try H.run(H.neutral(xo), x)
            let d = Sig.db(Sig.amplitude(y[0][24000..<48000], freq: f)) - Sig.db(Sig.amplitude(x[0][24000..<48000], freq: f))
            #expect(abs(d) < 0.1, "\(f) Hz: \(d) dB")
        }
        // Noise through the neutral multiband = the same noise through the three LR4 allpasses, delayed by the look-ahead.
        let noise = Sig.noise(amplitude: 0.5, count: 48000, seed: 3)
        let y = try H.run(H.neutral(xo), [noise, noise])
        var ref = noise.map(Double.init)
        for f in [xo[0], xo[1], xo[2]] { ref = LR4Allpass.run(ref, freq: f, sampleRate: 48000) }
        let L = MultibandStage.latency
        var err = 0.0, sig = 0.0
        for i in 0..<(noise.count - L) { let e = Double(y[0][i + L]) - ref[i]; err += e * e; sig += ref[i] * ref[i] }
        #expect(10 * log10(err / sig) < -100, "null \(10 * log10(err / sig)) dB")
    }

    @Test func defaultMultibandIsTransparentBelowThreshold() throws {
        // The effect as added from the catalog (thresholds -20 dB): a signal well below the thresholds passes unchanged.
        let e = try #require(ClipEffect.make(kind: ClipEffect.audioMultibandKind))
        guard case .multiband(let v) = e.audioStage(atLocal: .zero) else { Issue.record("mb"); return }
        #expect(!v.limiterOn)
        for f in [80.0, 400, 1500, 6000] {
            let x = Sig.sine(freq: f, amplitudeDB: -40, seconds: 1)
            let y = try H.run(v, x)
            let d = Sig.db(Sig.amplitude(y[0][24000..<48000], freq: f)) - Sig.db(Sig.amplitude(x[0][24000..<48000], freq: f))
            #expect(abs(d) < 0.1, "\(f) Hz: \(d) dB")
        }
    }

    @Test func limiterOnNeverExceedsTheCeilingAndNothingProducesNaN() throws {
        // Fuzz: hot noise and bursts (+12 dBFS), random settings and margins, gains ramping between blocks.
        var seed: UInt64 = 5                                   // deterministic LCG
        func r(_ a: Double, _ b: Double) -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return a + (b - a) * Double(seed >> 11) / Double(1 << 53) }
        for trial in 0..<12 {
            let n = 24000
            let burst = (0..<n).map { i -> Float in Float(sin(Double(i) * 0.07) * (i % 6000 < 300 ? 4 : 0.3)) }
            let noise = Sig.noise(amplitude: Float(r(0.1, 4)), count: n, seed: UInt64(trial + 1))
            let x = [zip(burst, noise).map { $0 + $1 }, noise]
            func v() -> AudioMultibandValues {
                AudioMultibandValues(outputGainDB: r(-18, 18), crossoverHz: SIMD3(r(20, 400), r(300, 3000), r(2000, 20000)),
                                     thresholdDB: SIMD4(r(-60, 0), r(-60, 0), r(-60, 0), r(-60, 0)),
                                     ratio: SIMD4(r(1, 30), r(1, 30), r(1, 30), r(1, 30)),
                                     attackMs: SIMD4(repeating: r(0.1, 50)), releaseMs: SIMD4(repeating: r(5, 2000)),
                                     gainDB: SIMD4(r(-18, 18), r(-18, 18), r(-18, 18), r(-18, 18)), limiterOn: true,
                                     limiterThresholdDB: r(-60, 0), limiterMarginDB: r(-18, 0), limiterReleaseMs: r(5, 5000),
                                     limiterAttackMs: r(0, 500))
            }
            let a = v(), b = { var b = v(); b.limiterMarginDB = a.limiterMarginDB; return b }()
            let l = [AudioFXSlot(id: UUID(), kind: ClipEffect.audioMultibandKind)]
            let chain = try ClipAudioFXChain(layout: l, channelCount: 2, maxFrames: 1024)
            let ceiling = Float(GainMath.linear(fromDB: a.limiterMarginDB))
            for (k, part) in Sig.chunked(x, sizes: [1024, 77, 512]).enumerated() {
                var buf = part
                let s0 = k.isMultiple(of: 2) ? a : b, s1 = k.isMultiple(of: 2) ? b : a
                chain.process(&buf, steps: [AudioFXStep(id: l[0].id, enabled: true, stage: .multiband(s0))],
                              endSteps: [AudioFXStep(id: l[0].id, enabled: true, stage: .multiband(s1))])
                for c in buf { for s in c { #expect(s.isFinite && abs(s) <= ceiling, "trial \(trial): \(s) > \(ceiling)") ; if !(s.isFinite && abs(s) <= ceiling) { return } } }
            }
        }
        // Limiter off with garbage in (NaN, inf, huge) and NaN settings: finite out.
        try nanSafety()
    }

    /// Switching the limiter or the whole effect on and off mid-signal: the samples still in the look-ahead line were driven
    /// (+8.9 dB) and must still be limited; nothing may pass the ceiling, not even by one ulp. -18 LUFS speech: dry peak
    /// -4.4 dBFS, limiter-off output -6.3 dBFS, so every sample of a correct output is at or under the ceiling.
    @Test func togglingLimiterOrEffectNeverPassesTheCeiling() throws {
        let x = H.speech(seconds: 6, targetLUFS: -18)
        let ceiling = Float(GainMath.linear(fromDB: -0.1))
        for mode in ["limiter", "effect"] {
            let l = [AudioFXSlot(id: UUID(), kind: ClipEffect.audioMultibandKind)]
            let chain = try ClipAudioFXChain(layout: l, channelCount: 2, maxFrames: 512)
            var worst: Float = 0
            for (k, part) in Sig.chunked(x, sizes: [512, 300, 97]).enumerated() {
                var buf = part
                let on = (k / 3).isMultiple(of: 2), on1 = ((k + 1) / 3).isMultiple(of: 2)
                func step(_ on: Bool) -> AudioFXStep {
                    mode == "limiter" ? AudioFXStep(id: l[0].id, enabled: true, stage: .multiband(H.broadcast(limiter: on)))
                                      : AudioFXStep(id: l[0].id, enabled: on, stage: .multiband(H.broadcast()))
                }
                chain.process(&buf, steps: [step(on)], endSteps: [step(on1)])
                for c in buf { for s in c { worst = max(worst, abs(s)) } }
            }
            #expect(worst <= ceiling, "\(mode) toggle: peak \(GainMath.dB(fromLinear: Double(worst))) dBFS")
        }
    }

    @Test func limiterNeverPassesTheCeilingByAnUlp() {
        // Unit level: a gain releasing back toward 1 (the near-unity snap) meets samples a few ulps over the ceiling.
        let lim = LookaheadLimiter(sampleRate: 48000, channels: 1, ceilingDB: -0.1, releaseMs: 5, attackMs: 1)
        let cf = Float(GainMath.linear(fromDB: -0.1))
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 100); defer { p.deallocate() }
        var bufs = [p]
        var worst: Float = 0, seed: UInt64 = 3
        for k in 0..<2000 {
            for i in 0..<100 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let ulps = Int(seed >> 61)                                     // 0...7 ulps over
                var v = cf; for _ in 0..<ulps { v = v.nextUp }
                p[i] = (k % 4 == 0 ? v : (k % 4 == 1 ? cf * 0.5 : v.nextUp)) * (i.isMultiple(of: 2) ? 1 : -1)
            }
            bufs.withUnsafeMutableBufferPointer { b in lim.process(b.baseAddress!, channels: 1, frames: 100) }
            if k > 0 { for i in 0..<100 { worst = max(worst, abs(p[i])) } }
        }
        #expect(worst <= cf, "\(worst) > \(cf)")
    }

    private func nanSafety() throws {
        var bad = H.neutral(); bad.thresholdDB = SIMD4(.nan, -10, -10, -10); bad.gainDB = SIMD4(.nan, 40, 0, 0); bad.outputGainDB = 18
        var x = Sig.sine(freq: 300, amplitudeDB: 20, seconds: 0.2)
        x[0][100] = .nan; x[1][200] = .infinity; x[0][300] = -.infinity
        for v in [bad, H.neutral()] {
            let y = try H.run(v, x)
            #expect(y.allSatisfy { $0.allSatisfy(\.isFinite) })
        }
    }
}

/// The LR4 allpass (LP + HP of two cascaded Butterworth biquads at `freq`), written independently of the DSP code.
enum LR4Allpass {
    static func run(_ x: [Double], freq: Double, sampleRate fs: Double) -> [Double] {
        let w = 2 * Double.pi * freq / fs, cw = cos(w), alpha = sin(w) / (2 * 0.5.squareRoot()), a0 = 1 + alpha
        let a1 = -2 * cw / a0, a2 = (1 - alpha) / a0
        let lp = [(1 - cw) / 2 / a0, (1 - cw) / a0, (1 - cw) / 2 / a0], hp = [(1 + cw) / 2 / a0, -(1 + cw) / a0, (1 + cw) / 2 / a0]
        func biquad(_ x: [Double], _ b: [Double]) -> [Double] {
            var z1 = 0.0, z2 = 0.0
            return x.map { v in let y = b[0] * v + z1; z1 = b[1] * v - a1 * y + z2; z2 = b[2] * v - a2 * y; return y }
        }
        let l = biquad(biquad(x, lp), lp), h = biquad(biquad(x, hp), hp)
        return zip(l, h).map { $0 + $1 }
    }
}
