import Foundation
import Testing
import SQCore
@testable import SQAudioFX

private func runChain(_ kind: String, _ stage: AudioFXStage, _ x: [[Float]], enabled: Bool = true, block: Int = 480) throws -> [[Float]] {
    let s = AudioFXSlot(id: UUID(), kind: kind)
    let chain = try ClipAudioFXChain(layout: [s], channelCount: x.count, maxFrames: block)
    var out: [[[Float]]] = []
    for part in Sig.chunked(x, sizes: [block]) {
        var b = part
        chain.process(&b, steps: [AudioFXStep(id: s.id, enabled: enabled, stage: stage)])
        out.append(b)
    }
    return Sig.concat(out, channels: x.count)
}

private func geq(_ gains: [Double], out: Double = 0) -> AudioFXStage { .graphicEQ(AudioGraphicEQValues(gainsDB: gains, outputDB: out)) }
private func tailGain(_ y: [Float], _ x: [Float]) -> Double { Sig.db(Sig.rms(y[24000...]) / Sig.rms(x[24000...])) }

@Suite struct GraphicEQTests {
    @Test func plusSixDBBandRaisesItsCenterAndLeavesAFarBand() throws {
        var g = [Double](repeating: 0, count: 10)
        g[5] = 6      // 1 kHz
        let at1k = Sig.sine(freq: 1000, amplitudeDB: -20, seconds: 1)
        let at31 = Sig.sine(freq: 31.5, amplitudeDB: -20, seconds: 1)
        let at16k = Sig.sine(freq: 16000, amplitudeDB: -20, seconds: 1)
        let c = tailGain(try runChain(ClipEffect.audioGraphicEQKind, geq(g), at1k)[0], at1k[0])
        let lo = tailGain(try runChain(ClipEffect.audioGraphicEQKind, geq(g), at31)[0], at31[0])
        let hi = tailGain(try runChain(ClipEffect.audioGraphicEQKind, geq(g), at16k)[0], at16k[0])
        print("graphic EQ +6 dB at 1 kHz: 1 kHz \(c) dB, 31.5 Hz \(lo) dB, 16 kHz \(hi) dB")
        #expect(abs(c - 6) < 0.3, "\(c)")
        #expect(abs(lo) < 0.5 && abs(hi) < 0.5, "\(lo) \(hi)")
    }

    @Test func everyBandHitsItsGainAtItsCenter() throws {
        for (i, hz) in AudioGraphicEQValues.bandHz.enumerated() {
            var g = [Double](repeating: 0, count: 10)
            g[i] = -9
            let x = Sig.sine(freq: hz, amplitudeDB: -20, seconds: 1)
            let y = tailGain(try runChain(ClipEffect.audioGraphicEQKind, geq(g), x)[0], x[0])
            #expect(abs(y + 9) < 0.5, "\(hz): \(y)")
        }
    }

    @Test func flatIsBitExactPassthrough() throws {
        let x = Sig.sine(freq: 1234, amplitudeDB: -6, seconds: 0.3)
        let y = try runChain(ClipEffect.audioGraphicEQKind, geq([Double](repeating: 0, count: 10)), x)
        #expect(y == x)
    }

    @Test func outputGainScalesAFlatEQ() throws {
        let x = Sig.sine(freq: 440, amplitudeDB: -20, seconds: 1)
        let y = try runChain(ClipEffect.audioGraphicEQKind, geq([Double](repeating: 0, count: 10), out: 6), x)
        #expect(abs(tailGain(y[0], x[0]) - 6) < 0.05)
    }

    @Test func disabledPassesThroughAndResultIsBlockSizeIndependent() throws {
        var g = [Double](repeating: 0, count: 10)
        g[3] = 8; g[7] = -5
        let x = Sig.sine(freq: 300, amplitudeDB: -12, seconds: 0.5)
        #expect(try runChain(ClipEffect.audioGraphicEQKind, geq(g), x, enabled: false) == x)
        let a = try runChain(ClipEffect.audioGraphicEQKind, geq(g), x, block: 480)
        let b = try runChain(ClipEffect.audioGraphicEQKind, geq(g), x, block: 128)
        let diff = zip(a[0], b[0]).map { abs($0 - $1) }.max() ?? 0
        #expect(diff < 1e-5, "\(diff)")
    }

    @Test func slotAddsNoLatency() throws {
        let chain = try ClipAudioFXChain(layout: [AudioFXSlot(id: UUID(), kind: ClipEffect.audioGraphicEQKind)], channelCount: 2, maxFrames: 256)
        #expect(chain.latencySamples == 0)
    }
}

@Suite struct GateHoldTests {
    private static func burstThenSilence() -> [[Float]] {
        let loud = Sig.sine(freq: 440, amplitudeDB: -10, seconds: 0.2)
        let quiet = Sig.sine(freq: 440, amplitudeDB: -80, seconds: 0.8)
        return [loud[0] + quiet[0], loud[1] + quiet[1]]
    }
    // Level of the 20 ms window starting `ms` after the burst ended (burst = 9600 samples).
    private func level(_ y: [Float], at ms: Double) -> Double {
        let s = 9600 + Int(ms * 48)
        return Sig.rms(y[s..<(s + 960)])
    }

    @Test func holdKeepsTheGateOpenForTheHoldTime() throws {
        let x = Self.burstThenSilence()
        let stage = { (hold: Double) in AudioFXStage.noiseGate(thresholdDB: -40, attackMs: 1, releaseMs: 5, rangeDB: 60, holdMs: hold) }
        let none = try runChain(ClipEffect.audioNoiseGateKind, stage(0), x)[0]
        let held = try runChain(ClipEffect.audioNoiseGateKind, stage(200), x)[0]
        // The quiet tail is -80 dB. Open gate = it passes unchanged; closed = pulled down 60 dB.
        let open = level(x[0], at: 100)
        print("gate hold: 100 ms after burst, no hold \(level(none, at: 100) / open), hold 200 \(level(held, at: 100) / open); 400 ms: \(level(held, at: 400) / open)")
        #expect(level(none, at: 100) < open * 0.01)
        #expect(level(held, at: 100) > open * 0.9)
        #expect(level(held, at: 400) < open * 0.01)
    }

    @Test func zeroHoldIsTheOldBehavior() throws {
        let x = Self.burstThenSilence()
        let a = try runChain(ClipEffect.audioNoiseGateKind, .noiseGate(thresholdDB: -40, attackMs: 1, releaseMs: 50, rangeDB: 60), x)
        let b = try runChain(ClipEffect.audioNoiseGateKind, .noiseGate(thresholdDB: -40, attackMs: 1, releaseMs: 50, rangeDB: 60, holdMs: 0), x)
        #expect(a == b)
    }
}

/// Runs `x` in blocks of 480; `steps(blockIndex)` gives the (start, end) stage of each block.
private func runBlocks(_ kind: String, _ x: [[Float]], block: Int = 480,
                       stages: (Int) -> (AudioFXStage, AudioFXStage)) throws -> [Float] {
    let s = AudioFXSlot(id: UUID(), kind: kind)
    let chain = try ClipAudioFXChain(layout: [s], channelCount: x.count, maxFrames: block)
    var out: [[[Float]]] = []
    for (i, part) in Sig.chunked(x, sizes: [block]).enumerated() {
        var b = part
        let (a, e) = stages(i)
        chain.process(&b, steps: [AudioFXStep(id: s.id, enabled: true, stage: a)], endSteps: [AudioFXStep(id: s.id, enabled: true, stage: e)])
        out.append(b)
    }
    return Sig.concat(out, channels: x.count)[0]
}

private func maxStep(_ y: [Float], _ r: Range<Int>) -> Float {
    var m: Float = 0
    for i in r.lowerBound + 1..<r.upperBound { m = max(m, abs(y[i] - y[i - 1])) }
    return m
}

@Suite struct GraphicEQRingOutTests {
    private static func bass() -> [[Float]] { Sig.sine(freq: 40, amplitudeDB: -12, seconds: 1) }
    private static func bands(_ g: Double) -> AudioFXStage {
        var v = AudioGraphicEQValues(); v[0] = g
        return .graphicEQ(v)
    }

    @Test func bandDroppingToZeroBetweenBlocksDoesNotJump() throws {
        let x = Self.bass()
        let y = try runBlocks(ClipEffect.audioGraphicEQKind, x) { i in
            let s = Self.bands(i < 50 ? 12 : 0); return (s, s)
        }
        let boundary = 50 * 480
        let steady = maxStep(y, 24000 - 4800..<24000)
        let around = maxStep(y, boundary - 4..<boundary + 4)
        print("graphic EQ +12 -> 0 between blocks: steady max step \(steady), at boundary \(around)")
        #expect(around <= steady * 1.5, "\(around) vs \(steady)")
    }

    @Test func keyframedDropToZeroInsideABlockDoesNotJump() throws {
        let x = Self.bass()
        let y = try runBlocks(ClipEffect.audioGraphicEQKind, x) { i in
            i < 50 ? (Self.bands(12), Self.bands(12)) : i == 50 ? (Self.bands(12), Self.bands(0)) : (Self.bands(0), Self.bands(0))
        }
        let steady = maxStep(y, 24000 - 4800..<24000)
        let around = maxStep(y, 50 * 480 - 4..<52 * 480)
        print("graphic EQ keyframed +12 -> 0 in a block: steady \(steady), around \(around)")
        #expect(around <= steady * 1.5, "\(around) vs \(steady)")
    }

    @Test func fullyDroppedBandIsBitExactAgainAfterItRang() throws {
        let x = Self.bass()
        let y = try runBlocks(ClipEffect.audioGraphicEQKind, x) { i in
            let s = Self.bands(i < 10 ? 12 : 0); return (s, s)
        }
        #expect(Array(y[(x[0].count - 2000)...]) == Array(x[0][(x[0].count - 2000)...]))
    }
}

@Suite struct GateHoldKeyframeTests {
    @Test func holdFallingToZeroShortensARunningHold() throws {
        let loud = Sig.sine(freq: 440, amplitudeDB: -10, seconds: 0.2), quiet = Sig.sine(freq: 440, amplitudeDB: -80, seconds: 0.8)
        let x = [loud[0] + quiet[0], loud[1] + quiet[1]]
        func stage(_ h: Double) -> AudioFXStage { .noiseGate(thresholdDB: -40, attackMs: 1, releaseMs: 5, rangeDB: 60, holdMs: h) }
        let y = try runBlocks(ClipEffect.audioNoiseGateKind, x) { i in
            let s = stage(i < 20 ? 1000 : 0); return (s, s)      // burst = 20 blocks of 480
        }
        let open = Sig.rms(x[0][9600 + 4800..<9600 + 5760])
        let tail = Sig.rms(y[9600 + 4800..<9600 + 5760])       // 100 ms after the burst
        print("gate hold 1000 -> 0 after the burst: 100 ms later \(tail / open)")
        #expect(tail < open * 0.01)
    }
}
