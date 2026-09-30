import Foundation
import Testing
import SSCore
@testable import SSAudioFX

@Suite struct GainTests {
    @Test func dbConversion() {
        #expect(AudioGain.linear(fromDB: 0) == 1)
        #expect(abs(AudioGain.linear(fromDB: 6.0206) - 2) < 1e-4)
        #expect(AudioGain.linear(fromDB: -.infinity) == 0)
        #expect(AudioGain.linear(fromDB: -120) == 0)
        #expect(AudioGain.dB(fromLinear: 0) == -.infinity)
        #expect(abs(AudioGain.dB(fromLinear: 0.5) + 6.0206) < 1e-3)
        #expect(abs(AudioGain.dB(fromLinear: AudioGain.linear(fromDB: -17.3)) + 17.3) < 1e-9)
    }

    @Test func staticGain() {
        var v = VolumeAutomation(staticDB: -6.0206)
        var b = Array(repeating: [Float](repeating: 1, count: 200), count: 2)
        v.apply(to: &b, start: .zero, sampleRate: 48000)
        for c in b { for s in c { #expect(abs(s - 0.5) < 1e-4) } }
    }

    @Test func muteIsExactSilence() {
        let v = VolumeAutomation(staticDB: -.infinity)
        var b = [[Float](repeating: 0.7, count: 100)]
        v.apply(to: &b, start: .zero, sampleRate: 48000)
        #expect(b[0].allSatisfy { $0 == 0 })
    }

    @Test func keyframedRampFollowsTrack() {
        var track = KeyframeTrack<Double>()
        track.insert(Keyframe(time: .zero, value: 0))
        track.insert(Keyframe(time: Time(1, 1), value: -20))
        let v = VolumeAutomation(staticDB: 0, track: track)
        var b = [[Float](repeating: 1, count: 48000)]
        v.apply(to: &b, start: .zero, sampleRate: 48000)
        // half way: -10 dB
        let mid = Double(b[0][24000])
        #expect(abs(20 * log10(mid) + 10) < 0.05)
        #expect(abs(b[0][0] - 1) < 1e-6)
    }

    @Test func chunkingGivesIdenticalResultAndNoSteps() {
        var track = KeyframeTrack<Double>()
        track.insert(Keyframe(time: Time(1, 10), value: 0))
        track.insert(Keyframe(time: Time(3, 10), value: -30, interpolation: .bezier))
        let v = VolumeAutomation(staticDB: 0, track: track)
        let n = 24000
        let ones = [[Float](repeating: 1, count: n)]
        var whole = ones
        v.apply(to: &whole, start: .zero, sampleRate: 48000)
        var parts: [[[Float]]] = []
        var pos = 0
        for len in [1, 63, 64, 65, 1000, 7, 4096] + Array(repeating: 333, count: 100) where pos < n {
            let l = min(len, n - pos)
            var p = [Array(ones[0][pos..<pos + l])]
            v.apply(to: &p, start: Time(Int64(pos), 48000), sampleRate: 48000)
            parts.append(p); pos += l
        }
        #expect(parts.flatMap { $0[0] } == whole[0])
        // zipper check: max sample-to-sample gain step is tiny
        var maxStep: Float = 0
        for i in 1..<n { maxStep = max(maxStep, abs(whole[0][i] - whole[0][i - 1])) }
        #expect(maxStep < 0.001)
    }

    @Test func panConstantPower() {
        var v = VolumeAutomation(staticDB: 0)
        v.pan = 0
        var b = Array(repeating: [Float](repeating: 1, count: 10), count: 2)
        v.apply(to: &b, start: .zero, sampleRate: 48000)
        #expect(abs(b[0][5] - 1) < 1e-5 && abs(b[1][5] - 1) < 1e-5)
        v.pan = 1
        b = Array(repeating: [Float](repeating: 1, count: 10), count: 2)
        v.apply(to: &b, start: .zero, sampleRate: 48000)
        #expect(abs(b[0][5]) < 1e-5)
        #expect(abs(b[1][5] - Float(2).squareRoot()) < 1e-4)
        v.pan = -0.5
        b = Array(repeating: [Float](repeating: 1, count: 10), count: 2)
        v.apply(to: &b, start: .zero, sampleRate: 48000)
        #expect(abs(b[0][5] * b[0][5] + b[1][5] * b[1][5] - 2) < 1e-4)
    }

    @Test func codableRoundTrip() throws {
        var t = KeyframeTrack<Double>()
        t.insert(Keyframe(time: .zero, value: -3))
        var v = VolumeAutomation(staticDB: 2, track: t); v.pan = 0.25
        let d = try JSONEncoder().encode(v)
        #expect(try JSONDecoder().decode(VolumeAutomation.self, from: d) == v)
    }
}
