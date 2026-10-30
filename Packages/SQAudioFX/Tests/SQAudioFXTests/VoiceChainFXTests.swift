import Foundation
import Testing
import SQCore
@testable import SQAudioFX

// AUDIO-FX-PRO: Multiband Compressor and 5-band Parametric EQ as clip chain stages.

private func slot(_ kind: String) -> AudioFXSlot { AudioFXSlot(id: UUID(), kind: kind) }
private func db(_ g: Double) -> Double { 20 * log10(g) }

private func mb(thr: Double = 0, ratio: Double = 1, out: Double = 0, gain: Double = 0) -> AudioMultibandValues {
    AudioMultibandValues(outputGainDB: out, crossoverHz: SIMD3(120, 700, 3000), thresholdDB: SIMD4(repeating: thr),
                         ratio: SIMD4(repeating: ratio), attackMs: SIMD4(repeating: 1), releaseMs: SIMD4(repeating: 50),
                         gainDB: SIMD4(repeating: gain))
}

private func flatEQ() -> AudioParametricEQValues {
    func b(_ hz: Double, on: Bool = true) -> AudioPEQBand { AudioPEQBand(on: on, hz: hz, gainDB: 0, q: 1) }
    return AudioParametricEQValues(hp: b(80, on: false), lowShelf: b(120), b1: b(100), b2: b(400), b3: b(1500), b4: b(4000), b5: b(10000),
                                   highShelf: b(8000), lp: b(16000, on: false))
}

@Suite struct VoiceChainFXTests {
    private func run(_ kind: String, _ stage: AudioFXStage, _ input: [[Float]], enabled: Bool = true, block: Int = 1024) throws -> [[Float]] {
        let l = [slot(kind)]
        let chain = try ClipAudioFXChain(layout: l, channelCount: input.count, maxFrames: block)
        let steps = [AudioFXStep(id: l[0].id, enabled: enabled, stage: stage)]
        var out: [[[Float]]] = []
        for part in Sig.chunked(input, sizes: [block]) {
            var b = part
            chain.process(&b, steps: steps)
            out.append(b)
        }
        return Sig.concat(out, channels: input.count)
    }
    private func tailPeak(_ y: [[Float]]) -> Double { y[0][24000...].map { Double(abs($0)) }.max() ?? 0 }

    // MARK: Multiband

    @Test func multibandReducesAboveThresholdOnly() throws {
        // 1.45 kHz is the middle of band 3. 24 dB over a -30 dB threshold at 4:1 leaves 6 dB over: about -24 dBFS ideal; the peak
        // detector ripple of a sine leaves a bit less).
        let loud = try run(ClipEffect.audioMultibandKind, .multiband(mb(thr: -30, ratio: 4)), Sig.sine(freq: 1450, amplitudeDB: -6, seconds: 1))
        let g = db(tailPeak(loud)); #expect(g < -17 && g > -26)   // 13...20 dB of reduction (18 dB ideal; ripple and skirts)
        let quiet = try run(ClipEffect.audioMultibandKind, .multiband(mb(thr: -30, ratio: 4)), Sig.sine(freq: 1450, amplitudeDB: -50, seconds: 1))
        #expect(abs(db(tailPeak(quiet)) - (-50)) < 0.3)
    }

    @Test func multibandOutputAndBandGainApply() throws {
        let x = Sig.sine(freq: 1450, amplitudeDB: -20, seconds: 0.6)
        let out = try run(ClipEffect.audioMultibandKind, .multiband(mb(out: 6)), x)
        #expect(abs(db(tailPeak(out)) - (-14)) < 0.2)
        var v = mb(); v.gainDB = SIMD4(0, 0, -6, 0)           // band 3 holds 1.45 kHz
        let band = try run(ClipEffect.audioMultibandKind, .multiband(v), x)
        #expect(db(tailPeak(band)) < -23 && db(tailPeak(band)) > -26.5)
    }

    @Test func multibandBandsCompressIndependently() throws {
        // Only band 1 (below 120 Hz) compresses: 1 kHz stays, 60 Hz drops.
        var v = mb(); v.thresholdDB = SIMD4(-40, 0, 0, 0); v.ratio = SIMD4(8, 1, 1, 1)
        let hi = try run(ClipEffect.audioMultibandKind, .multiband(v), Sig.sine(freq: 1000, amplitudeDB: -10, seconds: 1))
        let lo = try run(ClipEffect.audioMultibandKind, .multiband(v), Sig.sine(freq: 60, amplitudeDB: -10, seconds: 1))
        #expect(abs(db(tailPeak(hi)) - (-10)) < 0.5)
        #expect(db(tailPeak(lo)) < -22)
    }

    @Test func disabledMultibandPassesThroughAndBlockSizeDoesNotMatter() throws {
        let x = Sig.sine(freq: 800, amplitudeDB: -6, seconds: 0.3)
        // Disabled: unchanged, only delayed by the stage's fixed look-ahead latency (the chain's caller reads ahead by it).
        let off = try run(ClipEffect.audioMultibandKind, .multiband(mb(thr: -40, ratio: 8)), x, enabled: false)
        let L = MultibandStage.latency
        #expect(off[0].prefix(L).allSatisfy { $0 == 0 })
        #expect(Array(off[0][L...]) == Array(x[0][..<(x[0].count - L)]))
        let a = try run(ClipEffect.audioMultibandKind, .multiband(mb(thr: -30, ratio: 4)), x, block: 1024)
        let b = try run(ClipEffect.audioMultibandKind, .multiband(mb(thr: -30, ratio: 4)), x, block: 256)
        for i in 0..<a[0].count { #expect(abs(a[0][i] - b[0][i]) < 1e-6) }
    }

    /// The maintainer's Premiere "Broadcast" multiband on his voice clip (values read off Premiere's panel).
    private func broadcast(limiter: Bool) -> AudioMultibandValues {
        AudioMultibandValues(outputGainDB: 0, crossoverHz: SIMD3(137, 1147, 6910), thresholdDB: SIMD4(-15, -11, -17, -15),
                             ratio: SIMD4(3, 2, 2, 3), attackMs: SIMD4(repeating: 1), releaseMs: SIMD4(repeating: 100),
                             gainDB: SIMD4(4, -2, -4, -2), limiterOn: limiter, limiterThresholdDB: -9, limiterMarginDB: -0.1,
                             limiterReleaseMs: 500)
    }

    @Test func broadcastLimiterRaisesTheVoiceAndHoldsPeaksAtTheMargin() throws {
        // A voice peaking at -6 dBFS: compression and band gains roughly cancel, the limiter brings it up
        // by margin - threshold (+8.9 dB) and holds every peak at -0.1 dBFS. Without the limiter the voice was much quieter.
        let v = RoleChainTests.voice(seconds: 4, peakDB: -6)
        let x = [v, v]
        let off = try run(ClipEffect.audioMultibandKind, .multiband(broadcast(limiter: false)), x)
        let on = try run(ClipEffect.audioMultibandKind, .multiband(broadcast(limiter: true)), x)
        let rIn = db(Sig.rms(v[48000...])), rOff = db(Sig.rms(off[0][48000...])), rOn = db(Sig.rms(on[0][48000...]))
        #expect(rOff < rIn + 1)                                // the bands alone leave the level about where it was (measured -0.05 dB)
        #expect(rOn - rOff > 5)                                // measured +6.7 dB: the limiter's gain is what makes Premiere's voice loud
        #expect(rOn > rIn + 2)
        let peak = on.flatMap { $0 }.map { Double(abs($0)) }.max() ?? 0
        #expect(db(peak) <= -0.1 + 1e-4)
        #expect(on[0] == on[1])
    }

    @Test func limiterOffKeepsTheOldOutput() throws {
        let x = Sig.sine(freq: 800, amplitudeDB: -6, seconds: 0.3)
        var a = mb(thr: -30, ratio: 4); a.limiterThresholdDB = -20      // values are ignored while the limiter is off
        #expect(try run(ClipEffect.audioMultibandKind, .multiband(a), x) == run(ClipEffect.audioMultibandKind, .multiband(mb(thr: -30, ratio: 4)), x))
    }

    // MARK: Band solo / bypass, limiter attack, meters

    @Test func bypassedBandPassesUncompressedAndWithoutItsGain() throws {
        // Band 3 holds 1.45 kHz: compressed hard and cut 6 dB, then bypassed -> the tone comes out at its input level.
        let x = Sig.sine(freq: 1450, amplitudeDB: -6, seconds: 1)
        var v = mb(); v.thresholdDB = SIMD4(0, 0, -40, 0); v.ratio = SIMD4(1, 1, 10, 1); v.gainDB = SIMD4(0, 0, -6, 0)
        let squashed = try run(ClipEffect.audioMultibandKind, .multiband(v), x)
        #expect(db(tailPeak(squashed)) < -20)
        v.bandBypass = 0b0100
        let byp = try run(ClipEffect.audioMultibandKind, .multiband(v), x)
        #expect(abs(db(tailPeak(byp)) - (-6)) < 0.3)
        // Bypassing another band leaves band 3's compression in place.
        v.bandBypass = 0b0001
        #expect(db(tailPeak(try run(ClipEffect.audioMultibandKind, .multiband(v), x))) < -20)
    }

    @Test func soloLetsOnlySoloedBandsThrough() throws {
        var v = mb(); v.bandSolo = 0b0001                       // band 1: below 120 Hz
        let hi = try run(ClipEffect.audioMultibandKind, .multiband(v), Sig.sine(freq: 1450, amplitudeDB: -10, seconds: 1))
        let lo = try run(ClipEffect.audioMultibandKind, .multiband(v), Sig.sine(freq: 50, amplitudeDB: -10, seconds: 1))
        #expect(db(tailPeak(hi)) < -60)
        #expect(abs(db(tailPeak(lo)) - (-10)) < 0.5)
        v.bandSolo = 0b0101                                     // bands 1 + 3: 1.45 kHz comes back (band 3 alone, without the skirts of 2 / 4)
        let back = db(tailPeak(try run(ClipEffect.audioMultibandKind, .multiband(v), Sig.sine(freq: 1450, amplitudeDB: -10, seconds: 1))))
        #expect(back > -14 && back < -9)
    }

    @Test func allBandsSoloedOrNothingSetIsBitIdentical() throws {
        let x = RoleChainTests.voice(seconds: 1, peakDB: -6)
        let base = mb(thr: -30, ratio: 4, gain: 2)
        let ref = try run(ClipEffect.audioMultibandKind, .multiband(base), [x, x])
        var all = base; all.bandSolo = 0b1111
        #expect(try run(ClipEffect.audioMultibandKind, .multiband(all), [x, x]) == ref)
    }

    @Test func soloSwitchFadesInsteadOfClicking() throws {
        // A 1.45 kHz tone, band 1 soloed from the second block on: the tone fades within ~5 ms, no step.
        let x = Sig.sine(freq: 1450, amplitudeDB: -6, seconds: 0.2)
        let l = [slot(ClipEffect.audioMultibandKind)]
        let chain = try ClipAudioFXChain(layout: l, channelCount: 1, maxFrames: 1024)
        var solo = mb(); solo.bandSolo = 0b0001
        var out: [Float] = []
        for (k, part) in Sig.chunked(x, sizes: [1024]).enumerated() {
            var b = part
            chain.process(&b, steps: [AudioFXStep(id: l[0].id, enabled: true, stage: .multiband(k == 0 ? mb() : solo))])
            out += b[0]
        }
        let around = Array(out[1000..<1400])
        let step = zip(around.dropFirst(), around).map { abs(Double($0) - Double($1)) }.max() ?? 0
        let toneStep = 2 * Double.pi * 1450 / 48_000 * 0.5          // largest step of the tone itself
        #expect(step <= toneStep * 1.05)
        #expect((out[1024..<1104].map { abs($0) }.max() ?? 0) > 0.05)  // still fading during the first ms
        #expect(db(Double(out[4000...].map { abs($0) }.max() ?? 0)) < -60)
    }

    @Test func limiterAttackZeroIsTheOldLimiterAndLongerAttackStillHoldsTheMargin() throws {
        let v = RoleChainTests.voice(seconds: 2, peakDB: -3)
        let x = [v, v]
        var a = broadcast(limiter: true)
        let instant = try run(ClipEffect.audioMultibandKind, .multiband(a), x)
        a.limiterAttackMs = 4
        let slow = try run(ClipEffect.audioMultibandKind, .multiband(a), x)
        #expect(slow != instant)
        let peak = slow.flatMap { $0 }.map { Double(abs($0)) }.max() ?? 0
        #expect(db(peak) <= -0.1 + 1e-4)
        #expect(db(Sig.rms(slow[0][48000...])) >= db(Sig.rms(instant[0][48000...])) - 0.01)
    }

    @Test func masterLimiterAttackZeroMatchesTheDefault() {
        let x = RoleChainTests.voice(seconds: 0.5, peakDB: 0)
        var l1 = x, r1 = x, l2 = x, r2 = x
        var a = MasterLimiter(sampleRate: 48_000, ceilingDB: -6, releaseMs: 200)
        var b = MasterLimiter(sampleRate: 48_000, ceilingDB: -6, releaseMs: 200, attackMs: 0)
        l1.withUnsafeMutableBufferPointer { l in r1.withUnsafeMutableBufferPointer { r in a.process(left: l.baseAddress!, right: r.baseAddress!, count: l.count) } }
        l2.withUnsafeMutableBufferPointer { l in r2.withUnsafeMutableBufferPointer { r in b.process(left: l.baseAddress!, right: r.baseAddress!, count: l.count) } }
        #expect(l1 == l2 && r1 == r2)
    }

    @Test func metersPublishOnlyForTheWatchedEffect() throws {
        let tap = MultibandMeterTap.shared
        let l = [slot(ClipEffect.audioMultibandKind)]
        let chain = try ClipAudioFXChain(layout: l, channelCount: 2, maxFrames: 1024)
        let x = Sig.sine(freq: 1450, amplitudeDB: -6, seconds: 0.2)
        var v = mb(thr: -30, ratio: 4); v.limiterOn = true; v.limiterThresholdDB = -20; v.limiterMarginDB = -1
        func feed() { for part in Sig.chunked([x[0], x[0]], sizes: [1024]) { var b = part; chain.process(&b, steps: [AudioFXStep(id: l[0].id, enabled: true, stage: .multiband(v))]) } }
        tap.watch(UUID())
        let before = tap.reading(for: l[0].id)
        feed()
        #expect(before == nil && tap.reading(for: l[0].id) == nil)
        tap.watch(l[0].id)
        defer { tap.watch(nil) }
        let s0 = tap.sequence
        feed()
        let r = try #require(tap.reading(for: l[0].id))
        #expect(r.sequence > s0)
        #expect(abs(db(Double(r.inputPeak[2])) - (-6)) < 1)       // band 3 sees the tone
        #expect(r.inputPeak[0] < 0.05 && r.inputPeak[3] < 0.05)
        #expect(r.gainReductionDB[2] > 10 && r.gainReductionDB[0] < 0.01)
        #expect(r.limiterReductionDB > 0)
        v.bandBypass = 0b0100                                     // a bypassed band reduces nothing
        feed()
        #expect(tap.reading(for: l[0].id)!.gainReductionDB[2] == 0)
    }

    // MARK: Parametric EQ

    @Test func peakBandHitsItsGainAtItsFrequency() throws {
        var v = flatEQ(); v.b3 = AudioPEQBand(on: true, hz: 1500, gainDB: 9, q: 1)
        #expect(abs(PEQBiquad.totalMagnitudeDB(v, hz: 1500, fs: 48000) - 9) < 0.01)
        let y = try run(ClipEffect.audioParametricEQKind, .parametricEQ(v), Sig.sine(freq: 1500, amplitudeDB: -30, seconds: 0.6))
        #expect(abs(db(Sig.amplitude(y[0][12000...], freq: 1500)) - (-21)) < 0.2)
        let far = try run(ClipEffect.audioParametricEQKind, .parametricEQ(v), Sig.sine(freq: 60, amplitudeDB: -30, seconds: 0.6))
        #expect(abs(db(Sig.amplitude(far[0][12000...], freq: 60)) - (-30)) < 0.3)
    }

    @Test func shelvesAndCutFiltersShapeTheEnds() throws {
        var v = flatEQ()
        v.lowShelf = AudioPEQBand(on: true, hz: 200, gainDB: 6, q: 0.71)
        v.highShelf = AudioPEQBand(on: true, hz: 6000, gainDB: -6, q: 0.71)
        v.hp = AudioPEQBand(on: true, hz: 100, q: 0.7071)
        v.lp = AudioPEQBand(on: true, hz: 12000, q: 0.7071)
        #expect(abs(PEQBiquad.totalMagnitudeDB(v, hz: 1000, fs: 48000)) < 1)                // middle untouched
        #expect(PEQBiquad.totalMagnitudeDB(v, hz: 30, fs: 48000) < -6)                      // HP wins below 100 Hz
        #expect(PEQBiquad.totalMagnitudeDB(v, hz: 100, fs: 48000) < 3.5 && PEQBiquad.totalMagnitudeDB(v, hz: 100, fs: 48000) > -1.5)
        #expect(PEQBiquad.totalMagnitudeDB(v, hz: 16000, fs: 48000) < -9)                   // high shelf -6 plus LP
        let y = try run(ClipEffect.audioParametricEQKind, .parametricEQ(v), Sig.sine(freq: 40, amplitudeDB: -20, seconds: 0.6))
        let want = -20 + PEQBiquad.totalMagnitudeDB(v, hz: 40, fs: 48000)
        #expect(abs(db(Sig.amplitude(y[0][12000...], freq: 40)) - want) < 0.3)
    }

    @Test func eqOffBandsAndZeroGainAreBitExactAndDisabledPassesThrough() throws {
        let x = Sig.sine(freq: 440, amplitudeDB: -12, seconds: 0.2)
        #expect(try run(ClipEffect.audioParametricEQKind, .parametricEQ(flatEQ()), x) == x)
        var v = flatEQ(); v.b2 = AudioPEQBand(on: true, hz: 400, gainDB: 12, q: 1)
        #expect(try run(ClipEffect.audioParametricEQKind, .parametricEQ(v), x, enabled: false) == x)
        v.b2.on = false
        #expect(try run(ClipEffect.audioParametricEQKind, .parametricEQ(v), x) == x)
    }

    @Test func eqBlockSizeDoesNotChangeTheResult() throws {
        var v = flatEQ(); v.b4 = AudioPEQBand(on: true, hz: 4000, gainDB: -7, q: 2); v.hp = AudioPEQBand(on: true, hz: 90, q: 0.7071)
        let x = Sig.sine(freq: 3000, amplitudeDB: -10, seconds: 0.3)
        let a = try run(ClipEffect.audioParametricEQKind, .parametricEQ(v), x, block: 1024)
        let b = try run(ClipEffect.audioParametricEQKind, .parametricEQ(v), x, block: 100)
        for i in 0..<a[0].count { #expect(abs(a[0][i] - b[0][i]) < 1e-6) }
    }

    @Test func clipEffectValuesReachTheStages() throws {
        // Catalog defaults -> stage values -> a transparent EQ (all gains 0) and a compressing multiband.
        var c = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(60, 30)), start: .zero)
        let eqID = c.addEffect(kind: ClipEffect.audioParametricEQKind), mID = c.addEffect(kind: ClipEffect.audioMultibandKind)
        let eq = try #require(eqID), m = try #require(mID)
        c.setParameter(eq, ClipEffect.peqKey("b3", "Gain"), to: 9)
        c.setParameter(eq, ClipEffect.peqKey("hp", "On"), to: 1)
        c.setParameter(m, ClipEffect.mbThresholdKey(3), to: -30)
        c.setParameter(m, ClipEffect.mbRatioKey(3), to: 4)
        let steps = c.audioFXSteps(atLocal: .zero)
        guard case .parametricEQ(let ev) = steps[0].stage, case .multiband(let mv) = steps[1].stage else { Issue.record("stages"); return }
        #expect(ev.b3.gainDB == 9 && ev.hp.on && !ev.lp.on && ev.b3.hz == 1500)
        #expect(mv.thresholdDB[2] == -30 && mv.ratio[2] == 4 && mv.crossoverHz == SIMD3(120, 700, 3000))
        let chain = try ClipAudioFXChain(layout: c.audioFXLayout, channelCount: 2, maxFrames: 4096)
        var buf = Sig.sine(freq: 1500, amplitudeDB: -30, seconds: 0.05)
        chain.process(&buf, steps: steps)
        #expect(buf[0].allSatisfy { $0.isFinite })
    }

    @Test func multibandOutputGainRampsAcrossTheBlock() throws {
        let l = [slot(ClipEffect.audioMultibandKind)]
        let chain = try ClipAudioFXChain(layout: l, channelCount: 2, maxFrames: 4096)
        let a = AudioFXStep(id: l[0].id, enabled: true, stage: .multiband(mb(out: 0)))
        let b = AudioFXStep(id: l[0].id, enabled: true, stage: .multiband(mb(out: 12)))
        var x = Sig.sine(freq: 1450, amplitudeDB: -20, seconds: 4096.0 / 48000)
        chain.process(&x, steps: [a], endSteps: [b])
        func amp(_ r: Range<Int>) -> Double { Sig.amplitude(x[0][r], freq: 1450) }
        let w0 = amp(512..<768), w1 = amp(1536..<1792), w2 = amp(2560..<2816), w3 = amp(3584..<3840)
        #expect(w0 < w1 && w1 < w2 && w2 < w3)                       // rises through the block, no staircase
        #expect(abs(db(w3 / w0) - 12 * (3072.0 / 4096 - 0)) < 3.5)   // about 9 dB between the two windows
    }

    @Test func eqBandSwitchedOffFadesOutInsteadOfClicking() throws {
        let l = [slot(ClipEffect.audioParametricEQKind)]
        var on = flatEQ(); on.b3 = AudioPEQBand(on: true, hz: 1000, gainDB: 12, q: 1)
        var off = on; off.b3.on = false
        let chain = try ClipAudioFXChain(layout: l, channelCount: 1, maxFrames: 4096)
        var x = Sig.sine(freq: 1000, amplitudeDB: -20, seconds: 0.5, channels: 1)
        var out: [Float] = []
        for blk in 0..<4 {
            var b = [Array(x[0][blk * 4096..<(blk + 1) * 4096])]
            let cur = blk < 2 ? on : off
            let next = blk == 1 ? off : cur
            chain.process(&b, steps: [AudioFXStep(id: l[0].id, enabled: true, stage: .parametricEQ(cur))],
                          endSteps: [AudioFXStep(id: l[0].id, enabled: true, stage: .parametricEQ(next))])
            out += b[0]
        }
        x = [out]
        // After the fade the tone is back at its own level (-20 dB), and the fade is gradual.
        #expect(abs(db(Sig.amplitude(x[0][12288..<16384], freq: 1000)) - (-20)) < 0.3)
        let mid = Sig.amplitude(x[0][6144..<6656], freq: 1000), start = Sig.amplitude(x[0][4096..<4608], freq: 1000)
        #expect(mid < start && db(mid) > -20)
    }
}
