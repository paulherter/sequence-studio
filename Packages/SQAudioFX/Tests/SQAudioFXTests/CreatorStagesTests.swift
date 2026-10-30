import Foundation
import Testing
import SQCore
@testable import SQAudioFX

private func run(_ kind: String, _ stage: AudioFXStage, _ x: [[Float]], enabled: Bool = true, chunks: [Int] = [480]) throws -> [[Float]] {
    let s = AudioFXSlot(id: UUID(), kind: kind)
    let chain = try ClipAudioFXChain(layout: [s], channelCount: x.count, maxFrames: 480)
    var out: [[[Float]]] = []
    for part in Sig.chunked(x, sizes: chunks) {
        var b = part
        chain.process(&b, steps: [AudioFXStep(id: s.id, enabled: enabled, stage: stage)])
        out.append(b)
    }
    return Sig.concat(out, channels: x.count)
}
private func gainDB(_ y: [Float], _ x: [Float]) -> Double { Sig.db(Sig.rms(y[24000...]) / Sig.rms(x[24000...])) }

@Suite struct CreatorStagesTests {
    @Test func highCutSlopes() throws {
        func g(_ f: Double, order: Int) throws -> Double {
            let x = Sig.sine(freq: f, amplitudeDB: -20, seconds: 1)
            return gainDB(try run(ClipEffect.audioHighCutKind, .highCut(frequencyHz: 4000, order: order), x)[0], x[0])
        }
        #expect(abs(try g(4000, order: 2) + 3) < 0.7)
        #expect(abs(try g(200, order: 2)) < 0.1)
        let o1 = try g(16000, order: 1), o2 = try g(16000, order: 2), o3 = try g(16000, order: 3)
        #expect(o1 < -8 && o2 < o1 - 8 && o3 < o2 - 15, "\(o1) \(o2) \(o3)")
        let x = Sig.sine(freq: 12000, amplitudeDB: -20, seconds: 0.2)
        #expect(try run(ClipEffect.audioHighCutKind, .highCut(frequencyHz: 2000, order: 3), x, enabled: false) == x)
    }

    @Test func stereoWidthScalesTheSideSignal() throws {
        let l = Sig.sine(freq: 440, amplitudeDB: -12, seconds: 1)[0], r = Sig.sine(freq: 440, amplitudeDB: -12, seconds: 1, phase: 1)[0]
        let x = [l, r]
        // Width 100 % is transparent.
        let same = try run(ClipEffect.audioStereoWidthKind, .stereoWidth(width: 1), x)
        for i in stride(from: 0, to: l.count, by: 997) { #expect(abs(same[0][i] - l[i]) < 1e-5 && abs(same[1][i] - r[i]) < 1e-5) }
        // Width 0 = mono: both channels carry the mid.
        let mono = try run(ClipEffect.audioStereoWidthKind, .stereoWidth(width: 0), x)
        for i in stride(from: 0, to: l.count, by: 997) {
            #expect(abs(mono[0][i] - (l[i] + r[i]) / 2) < 1e-5 && mono[0][i] == mono[1][i])
        }
        // Width 200 %: side doubled, mid kept.
        let wide = try run(ClipEffect.audioStereoWidthKind, .stereoWidth(width: 2), x)
        for i in stride(from: 0, to: l.count, by: 997) {
            let m = (l[i] + r[i]) / 2, s = (l[i] - r[i]) / 2
            #expect(abs(wide[0][i] - (m + 2 * s)) < 1e-5 && abs(wide[1][i] - (m - 2 * s)) < 1e-5)
        }
        // A mono source (one channel) passes unchanged.
        let one = try run(ClipEffect.audioStereoWidthKind, .stereoWidth(width: 0), [l])
        #expect(one == [l])
        #expect(try run(ClipEffect.audioStereoWidthKind, .stereoWidth(width: 0), x, enabled: false) == x)
    }

    @Test func chorusMixesAModulatedCopyAndIsChunkIndependent() throws {
        let x = Sig.sine(freq: 1000, amplitudeDB: -12, seconds: 1)
        let stage = AudioFXStage.chorus(rateHz: 1, depthMs: 4, mix: 0.5)
        let a = try run(ClipEffect.audioChorusKind, stage, x, chunks: [480])
        let b = try run(ClipEffect.audioChorusKind, stage, x, chunks: [37, 480, 101])
        for i in stride(from: 0, to: x[0].count, by: 331) { #expect(abs(a[0][i] - b[0][i]) < 1e-5) }
        // The wet copy differs from the dry sound, and the output stays bounded.
        #expect(zip(a[0], x[0]).contains { abs($0 - $1) > 0.05 })
        #expect(a[0].allSatisfy { abs($0) <= 1.0 })
        // Mix 0 is the dry sound exactly.
        let dry = try run(ClipEffect.audioChorusKind, .chorus(rateHz: 1, depthMs: 4, mix: 0), x)
        #expect(dry == x)
        #expect(try run(ClipEffect.audioChorusKind, stage, x, enabled: false) == x)
    }
}
