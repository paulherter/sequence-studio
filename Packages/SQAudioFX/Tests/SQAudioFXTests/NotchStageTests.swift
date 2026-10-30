import Foundation
import Testing
import SQCore
@testable import SQAudioFX

private func runNotch(_ stage: AudioFXStage, _ x: [[Float]], enabled: Bool = true, block: Int = 480) throws -> [[Float]] {
    let s = AudioFXSlot(id: UUID(), kind: ClipEffect.audioNotchKind)
    let chain = try ClipAudioFXChain(layout: [s], channelCount: x.count, maxFrames: 1024)
    var out: [[[Float]]] = []
    for part in Sig.chunked(x, sizes: [block]) {
        var b = part
        chain.process(&b, steps: [AudioFXStep(id: s.id, enabled: enabled, stage: stage)])
        out.append(b)
    }
    return Sig.concat(out, channels: x.count)
}

private func tailGain(_ y: [Float], _ x: [Float]) -> Double { Sig.db(Sig.rms(y[24000...]) / Sig.rms(x[24000...])) }

@Suite struct NotchStageTests {
    @Test func attenuatesTheCenterByTheDepth() throws {
        for depth in [12.0, 30.0, 60.0] {
            let x = Sig.sine(freq: 1000, amplitudeDB: -12, seconds: 1)
            let y = try runNotch(.notch(frequencyHz: 1000, q: 10, depthDB: depth), x)
            let g = tailGain(y[0], x[0])
            print("notch depth \(depth) dB -> measured \(g) dB")
            #expect(g <= -(depth - 1), "\(depth): \(g)")
        }
    }

    @Test func leavesTwoOctavesAwayAlone() throws {
        for f in [250.0, 4000.0] {
            let x = Sig.sine(freq: f, amplitudeDB: -12, seconds: 1)
            let g = tailGain(try runNotch(.notch(frequencyHz: 1000, q: 10, depthDB: 40), x)[0], x[0])
            print("notch at 1 kHz, sine \(f) Hz -> \(g) dB")
            #expect(abs(g) < 0.5, "\(f): \(g)")
        }
    }

    @Test func widthStaysFOverQAtFullDepth() throws {
        func g(_ f: Double) throws -> Double {
            let x = Sig.sine(freq: f, amplitudeDB: -12, seconds: 1)
            return tailGain(try runNotch(.notch(frequencyHz: 1000, q: 10, depthDB: 60), x)[0], x[0])
        }
        let lo = try g(950), hi = try g(1050), center = try g(1000), far1 = try g(250), far2 = try g(4000)
        print("notch 60 dB Q10 1 kHz: 250 Hz \(far1) dB, 950 Hz \(lo) dB, 1000 Hz \(center) dB, 1050 Hz \(hi) dB, 4000 Hz \(far2) dB")
        #expect(abs(far1) < 0.5 && abs(far2) < 0.5)
        #expect(abs(lo + 3) < 1.5 && abs(hi + 3) < 1.5, "\(lo) \(hi)")
        #expect(center < -59)
    }

    @Test func silenceStaysSilence() throws {
        let x = [[Float]](repeating: [Float](repeating: 0, count: 48000), count: 2)
        let y = try runNotch(.notch(frequencyHz: 50, q: 10, depthDB: 30), x)
        #expect(y == x)
    }

    @Test func blockSizeDoesNotMatter() throws {
        let x = Sig.sine(freq: 997, amplitudeDB: -12, seconds: 0.5)
        let stage = AudioFXStage.notch(frequencyHz: 1000, q: 5, depthDB: 24)
        let a = try runNotch(stage, x, block: 64), b = try runNotch(stage, x, block: 1024)
        for c in 0..<2 { for i in a[c].indices { #expect(abs(a[c][i] - b[c][i]) < 1e-5) } }
    }

    @Test func zeroDepthAndDisabledAreBypass() throws {
        let x = Sig.sine(freq: 1000, amplitudeDB: -12, seconds: 0.3)
        #expect(try runNotch(.notch(frequencyHz: 1000, q: 10, depthDB: 0), x) == x)
        #expect(try runNotch(.notch(frequencyHz: 1000, q: 10, depthDB: 30), x, enabled: false) == x)
    }

    @Test func sweptParametersStayFiniteAndBounded() throws {
        let x = [Sig.noise(amplitude: 0.5, count: 48000), Sig.noise(amplitude: 0.5, count: 48000, seed: 2)]
        let s = AudioFXSlot(id: UUID(), kind: ClipEffect.audioNotchKind)
        let chain = try ClipAudioFXChain(layout: [s], channelCount: 2, maxFrames: 480)
        var peak: Float = 0
        for (k, part) in Sig.chunked(x, sizes: [480]).enumerated() {
            var b = part
            let f0 = 30 * pow(600, Double(k % 20) / 20), f1 = 30 * pow(600, Double((k + 1) % 20) / 20)
            chain.process(&b, steps: [AudioFXStep(id: s.id, enabled: true, stage: .notch(frequencyHz: f0, q: 40, depthDB: 60))],
                          endSteps: [AudioFXStep(id: s.id, enabled: true, stage: .notch(frequencyHz: f1, q: 40, depthDB: 60))])
            for ch in b { for v in ch { #expect(v.isFinite); peak = max(peak, abs(v)) } }
        }
        #expect(peak < 2)
    }
}
