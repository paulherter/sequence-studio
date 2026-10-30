import Foundation
import Testing
import SQCore
@testable import SQAudioFX

// AUDIO-FX: the per-clip effect chain runs its stages in list order on deinterleaved stereo.

private func slot(_ kind: String, _ id: UUID = UUID()) -> AudioFXSlot { AudioFXSlot(id: id, kind: kind) }
private func peak(_ x: [[Float]], from: Int = 0) -> Double {
    x.map { $0[from...].map { Double(abs($0)) }.max() ?? 0 }.max() ?? 0
}
private func db(_ g: Double) -> Double { 20 * log10(g) }

@Suite struct ClipAudioFXChainTests {
    private func run(_ layout: [AudioFXSlot], _ stages: [AudioFXStage], _ input: [[Float]], enabled: [Bool]? = nil,
                     block: Int = 1024) throws -> [[Float]] {
        let chain = try ClipAudioFXChain(layout: layout, channelCount: input.count, maxFrames: block)
        let steps = zip(layout, stages).enumerated().map { i, p in AudioFXStep(id: p.0.id, enabled: enabled?[i] ?? true, stage: p.1) }
        var out: [[[Float]]] = []
        for part in Sig.chunked(input, sizes: [block]) {
            var b = part
            chain.process(&b, steps: steps)
            out.append(b)
        }
        return Sig.concat(out, channels: input.count)
    }

    @Test func gainScalesTheSignal() throws {
        let x = Sig.sine(freq: 1000, amplitudeDB: -20, seconds: 0.1)
        let y = try run([slot(ClipEffect.audioGainKind)], [.gain(dB: 6)], x)
        #expect(abs(db(peak(y)) - (-14)) < 0.05)
    }

    @Test func orderMattersGainThenLimiterVersusLimiterThenGain() throws {
        let x = Sig.sine(freq: 1000, amplitudeDB: -6, seconds: 0.2)
        let g = slot(ClipEffect.audioGainKind), l = slot(ClipEffect.audioLimiterKind)
        // +6 dB into a -6 dB ceiling: the limiter has the last word.
        let gainFirst = try run([g, l], [.gain(dB: 6), .limiter(inputDB: 0, ceilingDB: -6)], x)
        // The limiter sees -6 dB (nothing to do), then +6 dB: 0 dBFS.
        let limiterFirst = try run([l, g], [.limiter(inputDB: 0, ceilingDB: -6), .gain(dB: 6)], x)
        #expect(db(peak(gainFirst, from: 4800)) <= -6 + 0.01)
        #expect(abs(db(peak(limiterFirst, from: 4800)) - 0) < 0.1)
    }

    @Test func disabledStagesPassThrough() throws {
        let x = Sig.sine(freq: 440, amplitudeDB: -12, seconds: 0.05)
        let y = try run([slot(ClipEffect.audioGainKind)], [.gain(dB: -40)], x, enabled: [false])
        #expect(y == x)
    }

    @Test func eqBoostsTheMidBandAndLeavesFarFrequencies() throws {
        let eq = AudioEQValues(lowGainDB: 0, lowHz: 100, midGainDB: 12, midHz: 1000, midQ: 1, highGainDB: 0, highHz: 8000)
        let at1k = try run([slot(ClipEffect.audioEQKind)], [.eq(eq)], Sig.sine(freq: 1000, amplitudeDB: -30, seconds: 0.5))
        let at50 = try run([slot(ClipEffect.audioEQKind)], [.eq(eq)], Sig.sine(freq: 50, amplitudeDB: -30, seconds: 0.5))
        let tail = 12000..<24000
        #expect(abs(db(Sig.amplitude(at1k[0][tail], freq: 1000)) - (-18)) < 0.3)
        #expect(abs(db(Sig.amplitude(at50[0][tail], freq: 50)) - (-30)) < 0.5)
    }

    @Test func shelvesActOnTheirSide() throws {
        let eq = AudioEQValues(lowGainDB: -12, lowHz: 200, midGainDB: 0, midHz: 1000, midQ: 1, highGainDB: 6, highHz: 4000)
        let low = try run([slot(ClipEffect.audioEQKind)], [.eq(eq)], Sig.sine(freq: 50, amplitudeDB: -20, seconds: 0.5))
        let high = try run([slot(ClipEffect.audioEQKind)], [.eq(eq)], Sig.sine(freq: 15000, amplitudeDB: -20, seconds: 0.5))
        let tail = 12000..<24000
        #expect(abs(db(Sig.amplitude(low[0][tail], freq: 50)) - (-32)) < 0.5)
        #expect(abs(db(Sig.amplitude(high[0][tail], freq: 15000)) - (-14)) < 0.5)
    }

    @Test func compressorReducesLoudPartsOnly() throws {
        let c = AudioFXStage.compressor(thresholdDB: -20, ratio: 4, attackMs: 1, releaseMs: 50, makeupDB: 0)
        let loud = try run([slot(ClipEffect.audioCompressorKind)], [c], Sig.sine(freq: 1000, amplitudeDB: -4, seconds: 0.5))
        let quiet = try run([slot(ClipEffect.audioCompressorKind)], [c], Sig.sine(freq: 1000, amplitudeDB: -30, seconds: 0.5))
        // 16 dB over the threshold at 4:1 leaves 4 dB over: about -16 dBFS.
        #expect(abs(db(peak(loud, from: 12000)) - (-16)) < 1)
        #expect(abs(db(peak(quiet, from: 12000)) - (-30)) < 0.05)
    }

    @Test func noiseReductionAddsTheDenoiserLatency() throws {
        let withNR = try ClipAudioFXChain(layout: [slot(ClipEffect.audioNoiseReductionKind), slot(ClipEffect.audioGainKind)],
                                          channelCount: 2, maxFrames: 512)
        let without = try ClipAudioFXChain(layout: [slot(ClipEffect.audioGainKind)], channelCount: 2, maxFrames: 512)
        #expect(withNR.latencySamples == 480)
        #expect(without.latencySamples == 0)
    }

    @Test func switchedOffNoiseReductionIsADelayedDryPath() throws {
        let x = [Sig.noise(amplitude: 0.1, count: 4800), Sig.noise(amplitude: 0.1, count: 4800, seed: 2)]
        let y = try run([slot(ClipEffect.audioNoiseReductionKind)], [.noiseReduction(amount: 0.8)], x, enabled: [false], block: 480)
        for c in 0..<2 { #expect(Array(y[c][480...]) == Array(x[c][..<(4800 - 480)])) }
    }

    @Test func blockSizeDoesNotChangeTheResult() throws {
        let layout = [slot(ClipEffect.audioEQKind), slot(ClipEffect.audioCompressorKind), slot(ClipEffect.audioDeEsserKind),
                      slot(ClipEffect.audioLimiterKind)]
        let stages: [AudioFXStage] = [
            .eq(AudioEQValues(lowGainDB: 3, lowHz: 120, midGainDB: -4, midHz: 900, midQ: 2, highGainDB: 2, highHz: 6000)),
            .compressor(thresholdDB: -24, ratio: 3, attackMs: 5, releaseMs: 80, makeupDB: 3),
            .deEsser(reductionDB: 8, sensitivity: 0.5),
            .limiter(inputDB: 3, ceilingDB: -2),
        ]
        let x = [Sig.noise(amplitude: 0.5, count: 9600), Sig.noise(amplitude: 0.5, count: 9600, seed: 7)]
        let a = try run(layout, stages, x, block: 1024)
        let b = try run(layout, stages, x, block: 256)
        #expect(a == b)
    }

    @Test func resetForgetsTheState() throws {
        let chain = try ClipAudioFXChain(layout: [slot(ClipEffect.audioCompressorKind)], channelCount: 2, maxFrames: 4800)
        let step = [AudioFXStep(id: chain.layout[0].id, enabled: true,
                                stage: .compressor(thresholdDB: -30, ratio: 10, attackMs: 1, releaseMs: 1000, makeupDB: 0))]
        let x = Sig.sine(freq: 1000, amplitudeDB: -6, seconds: 0.1)
        var first = x
        chain.process(&first, steps: step)
        chain.reset()
        var second = x
        chain.process(&second, steps: step)
        #expect(first == second)
    }

    @Test func gainRampsAcrossTheBlockToTheEndValue() throws {
        let s = slot(ClipEffect.audioGainKind)
        let chain = try ClipAudioFXChain(layout: [s], channelCount: 1, maxFrames: 1000)
        var x: [[Float]] = [Array(repeating: 1, count: 1000)]
        chain.process(&x, steps: [AudioFXStep(id: s.id, enabled: true, stage: .gain(dB: 0))],
                      endSteps: [AudioFXStep(id: s.id, enabled: true, stage: .gain(dB: -120))])
        #expect(abs(x[0][0] - 1) < 1e-6)
        #expect(x[0][999] < 0.01)
        #expect(x[0][500] < x[0][100])
    }

    @Test func deEsserReductionRampsAcrossTheBlock() throws {
        let s = slot(ClipEffect.audioDeEsserKind)
        let chain = try ClipAudioFXChain(layout: [s], channelCount: 1, maxFrames: 9600)
        var x: [[Float]] = Sig.sine(freq: 8000, amplitudeDB: -12, seconds: 0.2)
        chain.process(&x, steps: [AudioFXStep(id: s.id, enabled: true, stage: .deEsser(reductionDB: 0, sensitivity: 1))],
                      endSteps: [AudioFXStep(id: s.id, enabled: true, stage: .deEsser(reductionDB: 20, sensitivity: 1))])
        func peak(_ r: Range<Int>) -> Float { x[0][r].map(abs).max() ?? 0 }
        #expect(peak(2000..<2500) > 0.1)          // early: reduction still small
        #expect(peak(9000..<9600) < peak(2000..<2500) * 0.6)
    }

    @Test func eqBandReturningToZeroDBDoesNotClick() throws {
        let s = slot(ClipEffect.audioEQKind)
        let chain = try ClipAudioFXChain(layout: [s], channelCount: 1, maxFrames: 480)
        func v(_ g: Double) -> AudioEQValues { AudioEQValues(lowGainDB: g, lowHz: 200, midGainDB: 0, midHz: 1000, midQ: 1, highGainDB: 0, highHz: 8000) }
        let x = Sig.sine(freq: 100, amplitudeDB: -12, seconds: 0.1)
        var out: [Float] = []
        // 12 dB low shelf ramping to 0 dB over one block, then staying at 0 dB.
        let gains: [(Double, Double)] = [(12, 12), (12, 12), (12, 0), (0, 0), (0, 0)]
        for (i, g) in gains.enumerated() {
            var b: [[Float]] = [Array(x[0][(i * 480)..<((i + 1) * 480)])]
            chain.process(&b, steps: [AudioFXStep(id: s.id, enabled: true, stage: .eq(v(g.0)))],
                          endSteps: [AudioFXStep(id: s.id, enabled: true, stage: .eq(v(g.1)))])
            out += b[0]
        }
        // Largest sample-to-sample step stays near the sine's own slope (no jump at a block edge).
        let slope = zip(x[0].dropFirst(), x[0]).prefix(out.count - 1).map { abs($0 - $1) }.max()!
        let jumps = zip(out.dropFirst(), out).map { abs($0 - $1) }.max()!
        #expect(jumps < slope * 4.5)
        // Back at 0 dB the band is the identity: the last block is the input (to float rounding).
        for i in 2000..<2400 { #expect(abs(out[i] - x[0][i]) < 1e-4) }
    }

    @Test func limiterCeilingRampsAcrossTheBlock() throws {
        let s = slot(ClipEffect.audioLimiterKind)
        let chain = try ClipAudioFXChain(layout: [s], channelCount: 1, maxFrames: 4800)
        var x = Sig.sine(freq: 1000, amplitudeDB: 0, seconds: 0.1)
        chain.process(&x, steps: [AudioFXStep(id: s.id, enabled: true, stage: .limiter(inputDB: 0, ceilingDB: -1))],
                      endSteps: [AudioFXStep(id: s.id, enabled: true, stage: .limiter(inputDB: 0, ceilingDB: -13))])
        // Early part near -1 dB, the end near -13 dB: the ceiling moved inside the block, not in one step.
        #expect(db(peak([Array(x[0][300..<900])])) > -3)
        #expect(db(peak([Array(x[0][4600..<4800])])) < -11)
        #expect(db(peak([Array(x[0][2200..<2600])])) < -4 && db(peak([Array(x[0][2200..<2600])])) > -10)
    }
}

// Privacy: a stage without its step never passes the voice dry; the layout and the steps of every audio effect line up.
@Suite struct ClipAudioFXFailClosedTests {
    private func block() -> [[Float]] { Sig.sine(freq: 440, amplitudeDB: -12, seconds: 0.02) }

    @Test func missingOrMismatchedStepSilencesTheBlock() throws {
        let a = slot(ClipEffect.audioGainKind), b = slot(ClipEffect.audioDisguiseVoiceKind)
        let chain = try ClipAudioFXChain(layout: [a, b], channelCount: 2, maxFrames: 1024)
        var x = block()
        chain.process(&x, steps: [AudioFXStep(id: a.id, enabled: true, stage: .gain(dB: 0))])
        #expect(peak(x) == 0)
        var y = block()
        chain.process(&y, steps: [AudioFXStep(id: a.id, enabled: true, stage: .gain(dB: 0)),
                                  AudioFXStep(id: UUID(), enabled: true, stage: .gain(dB: 0))])
        #expect(peak(y) == 0)
    }

    @Test func switchedOffEffectsStillPassDry() throws {
        let a = slot(ClipEffect.audioGainKind)
        let chain = try ClipAudioFXChain(layout: [a], channelCount: 2, maxFrames: 1024)
        var x = block()
        let before = peak(x)
        chain.process(&x, steps: [AudioFXStep(id: a.id, enabled: false, stage: .gain(dB: 12))])
        #expect(peak(x) == before)
    }

    @Test func layoutAndStepsAlignForEveryAudioKind() throws {
        let kinds = Array(Set(EffectCatalog.audio.map(\.kind) + [ClipEffect.audioDisguiseVoiceKind]))
        var clip = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(60, 30)), start: .zero)
        for k in kinds { _ = clip.addEffect(kind: k) }
        #expect(clip.effects.count == kinds.count)
        if let e = ClipEffect.make(kind: "audio.unknownFutureKind") { clip.effects.append(e) }
        else { clip.effects.append(ClipEffect(kind: "audio.unknownFutureKind")) }
        let layout = clip.audioFXLayout
        let steps = clip.audioFXSteps(atLocal: .zero)
        #expect(layout.count == kinds.count)                      // the unknown kind is in neither
        #expect(steps.count == layout.count)
        #expect(zip(layout, steps).allSatisfy { $0.id == $1.id })
        #expect(clip.audioFXLayoutMatches(layout))
        let chain = try ClipAudioFXChain(layout: layout, channelCount: 2, maxFrames: 1024)
        var x = block()
        chain.process(&x, steps: steps)
        #expect(x[0].allSatisfy { $0.isFinite })
    }
}
