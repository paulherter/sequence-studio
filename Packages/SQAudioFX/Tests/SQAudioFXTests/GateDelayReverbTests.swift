import Foundation
import Testing
import SQCore
@testable import SQAudioFX

private func slot(_ kind: String) -> AudioFXSlot { AudioFXSlot(id: UUID(), kind: kind) }
private func run(_ s: AudioFXSlot, _ stage: AudioFXStage, _ x: [[Float]], enabled: Bool = true, block: Int = 480) throws -> [[Float]] {
    let chain = try ClipAudioFXChain(layout: [s], channelCount: x.count, maxFrames: block)
    var out: [[[Float]]] = []
    for part in Sig.chunked(x, sizes: [block]) {
        var b = part
        chain.process(&b, steps: [AudioFXStep(id: s.id, enabled: enabled, stage: stage)])
        out.append(b)
    }
    return Sig.concat(out, channels: x.count)
}
private func rms(_ x: [Float], _ r: Range<Int>) -> Double { Sig.rms(x[r]) }

@Suite struct GateDelayReverbTests {
    @Test func gateClosesOnQuietAndOpensOnLoud() throws {
        // 0.5 s quiet (-60 dB) then 0.5 s loud (-10 dB).
        let quiet = Sig.sine(freq: 440, amplitudeDB: -60, seconds: 0.5), loud = Sig.sine(freq: 440, amplitudeDB: -10, seconds: 0.5)
        let x = [quiet[0] + loud[0], quiet[1] + loud[1]]
        let s = slot(ClipEffect.audioNoiseGateKind)
        let y = try run(s, .noiseGate(thresholdDB: -40, attackMs: 1, releaseMs: 50, rangeDB: 60), x)
        #expect(rms(y[0], 12000..<24000) < rms(x[0], 12000..<24000) * 0.01)       // at least -40 dB further down
        #expect(abs(rms(y[0], 30000..<46000) / rms(x[0], 30000..<46000) - 1) < 0.02) // loud part untouched
    }

    @Test func gateRangeSetsTheFloor() throws {
        let x = Sig.sine(freq: 440, amplitudeDB: -50, seconds: 0.5)
        let y = try run(slot(ClipEffect.audioNoiseGateKind), .noiseGate(thresholdDB: -30, attackMs: 1, releaseMs: 20, rangeDB: 12), x)
        let ratio = rms(y[0], 12000..<24000) / rms(x[0], 12000..<24000)
        #expect(abs(20 * log10(ratio) + 12) < 0.5)
    }

    @Test func disabledGatePassesThrough() throws {
        let x = Sig.sine(freq: 440, amplitudeDB: -60, seconds: 0.1)
        #expect(try run(slot(ClipEffect.audioNoiseGateKind), .noiseGate(thresholdDB: -20, attackMs: 1, releaseMs: 20, rangeDB: 60), x, enabled: false) == x)
    }

    @Test func delayEchoesAfterTheSetTime() throws {
        var impulse = [[Float]](repeating: [Float](repeating: 0, count: 48000), count: 2)
        impulse[0][0] = 1; impulse[1][0] = 1
        let y = try run(slot(ClipEffect.audioDelayKind), .delay(timeMs: 100, feedback: 0.5, mix: 0.5), impulse)
        #expect(abs(y[0][0] - 0.5) < 1e-4)            // dry share
        #expect(abs(y[0][4800] - 0.5) < 1e-4)         // first echo at 100 ms: input 1 * mix 0.5
        #expect(abs(y[0][9600] - 0.25) < 1e-4)       // second echo, feedback 0.5
        #expect(abs(y[0][2400]) < 1e-6)
    }

    @Test func delayMixZeroIsDry() throws {
        let x = Sig.sine(freq: 300, amplitudeDB: -12, seconds: 0.2)
        let y = try run(slot(ClipEffect.audioDelayKind), .delay(timeMs: 200, feedback: 0.9, mix: 0), x)
        for i in 0..<x[0].count { #expect(abs(y[0][i] - x[0][i]) < 1e-5) }
    }

    @Test func delayAtMaximumTimeAndFeedbackStaysBounded() throws {
        let x = [Sig.noise(amplitude: 0.5, count: 96000), Sig.noise(amplitude: 0.5, count: 96000, seed: 2)]
        let y = try run(slot(ClipEffect.audioDelayKind), .delay(timeMs: 2000, feedback: 0.95, mix: 1), x)
        #expect(y[0].allSatisfy { $0.isFinite && abs($0) < 20 })
    }

    @Test func reverbHasATailAndDecays() throws {
        var impulse = [[Float]](repeating: [Float](repeating: 0, count: 96000), count: 2)
        impulse[0][0] = 1; impulse[1][0] = 1
        let y = try run(slot(ClipEffect.audioReverbKind), .reverb(roomSize: 0.7, damping: 0.5, mix: 1), impulse)
        let early = rms(y[0], 2400..<9600), late = rms(y[0], 72000..<96000)
        #expect(early > 1e-3)
        #expect(late < early)
        #expect(y[0].allSatisfy { $0.isFinite })
        #expect(abs(y[0][0]) < 0.05)                  // wet only: the first echoes need the comb delays (>= 25 ms)
    }

    @Test func reverbMixZeroIsDryAndBiggerRoomRingsLonger() throws {
        let x = Sig.sine(freq: 300, amplitudeDB: -12, seconds: 0.1)
        let dry = try run(slot(ClipEffect.audioReverbKind), .reverb(roomSize: 0.5, damping: 0.5, mix: 0), x)
        for i in 0..<x[0].count { #expect(abs(dry[0][i] - x[0][i]) < 1e-5) }
        var imp = [[Float]](repeating: [Float](repeating: 0, count: 96000), count: 2)
        imp[0][0] = 1; imp[1][0] = 1
        let small = try run(slot(ClipEffect.audioReverbKind), .reverb(roomSize: 0.2, damping: 0.5, mix: 1), imp)
        let big = try run(slot(ClipEffect.audioReverbKind), .reverb(roomSize: 0.9, damping: 0.5, mix: 1), imp)
        #expect(rms(big[0], 48000..<96000) > rms(small[0], 48000..<96000))
    }

    @Test func stereoReverbDecorrelatesTheChannels() throws {
        var imp = [[Float]](repeating: [Float](repeating: 0, count: 24000), count: 2)
        imp[0][0] = 1; imp[1][0] = 1
        let y = try run(slot(ClipEffect.audioReverbKind), .reverb(roomSize: 0.7, damping: 0.5, mix: 1), imp)
        #expect(y[0] != y[1])
    }

    @Test func chainStagesAreIndependentAcrossBlockSizes() throws {
        let x = Sig.sine(freq: 440, amplitudeDB: -12, seconds: 0.3)
        let s = slot(ClipEffect.audioDelayKind)
        let a = try run(s, .delay(timeMs: 50, feedback: 0.4, mix: 0.4), x, block: 480)
        let b = try run(s, .delay(timeMs: 50, feedback: 0.4, mix: 0.4), x, block: 997)
        for i in 0..<a[0].count { #expect(abs(a[0][i] - b[0][i]) < 1e-5) }
    }
}
