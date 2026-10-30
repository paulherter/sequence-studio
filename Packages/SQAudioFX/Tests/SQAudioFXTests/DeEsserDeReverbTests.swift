import Foundation
import Testing
import SQCore
@testable import SQAudioFX

private func slot(_ kind: String) -> AudioFXSlot { AudioFXSlot(id: UUID(), kind: kind) }

/// Runs one effect over `input` in 1024-frame blocks (mono) and returns the output.
private func run(_ kind: String, _ stage: AudioFXStage, _ input: [Float], enabled: Bool = true) throws -> (out: [Float], latency: Int) {
    let s = slot(kind)
    let chain = try ClipAudioFXChain(layout: [s], channelCount: 1, maxFrames: 1024)
    let step = AudioFXStep(id: s.id, enabled: enabled, stage: stage)
    var out: [Float] = []
    var i = 0
    while i < input.count {
        let k = min(1024, input.count - i)
        var b: [[Float]] = [Array(input[i..<(i + k)])]
        chain.process(&b, steps: [step])
        out += b[0]
        i += k
    }
    return (out, chain.latencySamples)
}

private func db(_ a: Double, _ b: Double) -> Double { 20 * log10(max(a, 1e-12) / max(b, 1e-12)) }

@Suite struct DeEsserControlsTests {
    /// Mixed signal: a 300 Hz voice body plus a burst of sibilance at `hz`.
    static func voice(sibilantHz: Double) -> [Float] {
        let n = 48_000
        return (0..<n).map { i in
            let t = Double(i) / 48_000
            let body = 0.25 * sin(2 * Double.pi * 300 * t)
            let burst = (t > 0.3 && t < 0.7) ? 0.3 * sin(2 * Double.pi * sibilantHz * t) : 0
            return Float(body + burst)
        }
    }
    static func burstRMS(_ x: [Float]) -> Double { Sig.rms(x[19_200..<33_600]) }   // 0.4 s...0.7 s

    @Test func defaultsAreTheOldBehaviourBitForBit() throws {
        let x = Self.voice(sibilantHz: 7_000)
        let old = try run(ClipEffect.audioDeEsserKind, .deEsser(reductionDB: 10, sensitivity: 0.5), x).out
        let neutral = try run(ClipEffect.audioDeEsserKind, .deEsser(reductionDB: 10, sensitivity: 0.5, frequencyHz: 7_000, range: 1, speed: 1, listen: false), x).out
        #expect(old == neutral)
        // And the catalog defaults evaluate to exactly that stage.
        var clip = Clip(name: "A", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(60, 1)), start: .zero,
                        mediaDuration: Time(60, 1))
        _ = clip.addEffect(kind: ClipEffect.audioDeEsserKind)
        guard case .deEsser(let red, let sens, let f, let r, let sp, let l)? = clip.audioFXSteps(atLocal: .zero).first?.stage else { Issue.record("no stage"); return }
        #expect(red == 10 && sens == 0.5)
        #expect(f == 7_000 && r == 1 && sp == 1 && !l)
    }

    @Test func frequencyMovesTheTarget() throws {
        let x = Self.voice(sibilantHz: 4_000)
        let at7k = try run(ClipEffect.audioDeEsserKind, .deEsser(reductionDB: 16, sensitivity: 0.8, frequencyHz: 7_000), x).out
        let at4k = try run(ClipEffect.audioDeEsserKind, .deEsser(reductionDB: 16, sensitivity: 0.8, frequencyHz: 4_000), x).out
        // Targeting the real sibilance reduces it clearly more than aiming at 7 kHz.
        #expect(Self.burstRMS(at4k) < Self.burstRMS(at7k) * 0.8)
    }

    @Test func narrowLeavesTheRestOfTheHighsAlone() throws {
        // Sibilance at 7 kHz plus an 11 kHz tone: Narrow keeps the 11 kHz, All HF takes it down too.
        let n = 48_000
        let x: [Float] = (0..<n).map { i in
            let t = Double(i) / 48_000
            let s = (t > 0.3 && t < 0.7) ? 0.3 * sin(2 * Double.pi * 7_000 * t) : 0
            return Float(0.25 * sin(2 * Double.pi * 300 * t) + s + 0.15 * sin(2 * Double.pi * 11_000 * t))
        }
        func high(_ y: [Float]) -> Double {      // 11 kHz level via a one-bin DFT over the burst
            var re = 0.0, im = 0.0
            for i in 19_200..<33_600 { let p = 2 * Double.pi * 11_000 * Double(i) / 48_000; re += Double(y[i]) * cos(p); im += Double(y[i]) * sin(p) }
            return hypot(re, im) / 14_400
        }
        let narrow = try run(ClipEffect.audioDeEsserKind, .deEsser(reductionDB: 20, sensitivity: 0.9, frequencyHz: 7_000, range: 0), x).out
        let all = try run(ClipEffect.audioDeEsserKind, .deEsser(reductionDB: 20, sensitivity: 0.9, frequencyHz: 7_000, range: 2), x).out
        #expect(high(narrow) > high(all) * 1.3)
    }

    @Test func listenPlaysOnlyTheRemovedEss() throws {
        let x = Self.voice(sibilantHz: 7_000)
        let heard = try run(ClipEffect.audioDeEsserKind, .deEsser(reductionDB: 12, sensitivity: 0.8, listen: true), x).out
        // The 300 Hz body is not in it; the sibilance burst is.
        #expect(Sig.rms(heard[2_000..<9_000]) < 0.01)
        #expect(Sig.rms(heard[22_000..<30_000]) > 0.02)
    }

    @Test func speedChangesHowFastItLetsGo() throws {
        // A short ess: slow release keeps the reduction longer after it ends than fast.
        let x: [Float] = (0..<24_000).map { i in
            let t = Double(i) / 48_000
            return Float(0.2 * sin(2 * Double.pi * 300 * t) + ((t > 0.1 && t < 0.2) ? 0.3 * sin(2 * Double.pi * 7_000 * t) : 0))
        }
        func tail(_ speed: Int) throws -> Double {
            let y = try run(ClipEffect.audioDeEsserKind, .deEsser(reductionDB: 20, sensitivity: 0.9, speed: speed), x).out
            return Sig.rms(y[9_700..<10_500])         // just after the ess ends, 7 kHz band only matters: use whole level
        }
        let fast = try tail(0), slow = try tail(2)
        #expect(fast != slow)
    }
}

@Suite struct DeReverbTests {
    static let fs = 48_000
    /// A "dry" noise burst of `burst` seconds followed by an exponentially decaying noise tail (RT60 `rt60`), the tail starting
    /// at `tailStart` x the burst level. Returns the signal and the sample where the burst ends.
    static func burstAndTail(burst: Double, rt60: Double, tailStart: Double = 0.3, total: Double = 1.6) -> ([Float], Int) {
        let n = Int(total * Double(fs)), b = Int(burst * Double(fs))
        let noise = Sig.noise(amplitude: 0.3, count: n, seed: 7)
        let out: [Float] = (0..<n).map { i in
            if i < b { return noise[i] }
            let t = Double(i - b) / Double(fs)
            return noise[i] * Float(tailStart * exp(-6.9078 * t / rt60))
        }
        return (out, b)
    }

    @Test func declaresItsDelayAndPassesAudioDelayedAtZeroAmount() throws {
        let x = Sig.noise(amplitude: 0.3, count: 12_000, seed: 3)
        let r = try run(ClipEffect.audioDeReverbKind, .deReverb(amount: 0, decaySeconds: 0.6, tone: 0), x)
        #expect(r.latency == AudioDeReverbValues.latencySamples)
        let d = r.latency
        var worst: Float = 0
        for i in 0..<(x.count - d) { worst = max(worst, abs(r.out[i + d] - x[i])) }
        #expect(worst < 1e-4)
        // The delay holds while the effect is switched off.
        let off = try run(ClipEffect.audioDeReverbKind, .deReverb(amount: 1, decaySeconds: 0.6, tone: 0), x, enabled: false)
        for i in 0..<(x.count - d) { worst = max(worst, abs(off.out[i + d] - x[i])) }
        #expect(worst < 1e-4)
    }

    @Test func reducesALateReverbTail() throws {
        let (x, end) = Self.burstAndTail(burst: 0.4, rt60: 0.6)
        let r = try run(ClipEffect.audioDeReverbKind, .deReverb(amount: 0.8, decaySeconds: 0.6, tone: 0), x)
        let d = r.latency
        // The tail 150...450 ms after the dry sound, input against output (output delayed by `d`).
        let a = end + 7_200, b = end + 21_600
        let before = Sig.rms(x[a..<b]), after = Sig.rms(r.out[(a + d)..<(b + d)])
        let reduction = db(before, after)
        #expect(reduction > 6, "tail reduced by \(reduction) dB")
    }

    @Test func moreAmountReducesMore() throws {
        let (x, end) = Self.burstAndTail(burst: 0.4, rt60: 0.6)
        func lvl(_ amount: Double) throws -> Double {
            let r = try run(ClipEffect.audioDeReverbKind, .deReverb(amount: amount, decaySeconds: 0.6, tone: 0), x)
            let d = r.latency
            return Sig.rms(r.out[(end + 7_200 + d)..<(end + 21_600 + d)])
        }
        let low = try lvl(0.3), high = try lvl(0.9)
        #expect(high < low)
    }

    /// Speech-like: 4 Hz syllables of a harmonic voice (150 Hz + harmonics) with pauses, no reverb at all.
    static func speechLike(seconds: Double) -> [Float] {
        let n = Int(seconds * Double(fs))
        return (0..<n).map { i in
            let t = Double(i) / Double(fs)
            let syl = max(0, sin(2 * Double.pi * 2.5 * t))            // 0.4 s period, ~0.2 s voiced... smooth on/off
            let env = pow(syl, 0.5)
            var v = 0.0
            for h in 1...12 { v += sin(2 * Double.pi * 150 * Double(h) * t) / Double(h) }
            return Float(0.15 * env * v)
        }
    }

    @Test func leavesDrySpeechLikeSignalAlone() throws {
        let x = Self.speechLike(seconds: 3)
        let r = try run(ClipEffect.audioDeReverbKind, .deReverb(amount: 0.5, decaySeconds: 0.6, tone: 0), x)
        let d = r.latency
        // Level of the voiced cores (envelope above 0.7), input against delayed output: within 1.5 dB.
        var sumIn = 0.0, sumOut = 0.0, count = 0.0
        for i in 24_000..<(x.count - d) {
            let t = Double(i) / Double(Self.fs)
            if sin(2 * Double.pi * 2.5 * t) > 0.7 {
                sumIn += Double(x[i]) * Double(x[i]); sumOut += Double(r.out[i + d]) * Double(r.out[i + d]); count += 1
            }
        }
        let loss = db(sqrt(sumIn / count), sqrt(sumOut / count))
        #expect(loss < 1.5, "voiced cores lost \(loss) dB")
    }

    @Test func toneShiftsTheReductionBetweenLowsAndHighs() throws {
        let (x, end) = Self.burstAndTail(burst: 0.4, rt60: 0.6)
        func lvl(_ tone: Double) throws -> Double {
            let r = try run(ClipEffect.audioDeReverbKind, .deReverb(amount: 0.6, decaySeconds: 0.6, tone: tone), x)
            let d = r.latency
            return Sig.rms(r.out[(end + 7_200 + d)..<(end + 21_600 + d)])
        }
        let darker = try lvl(-1), brighter = try lvl(1)
        #expect(darker != brighter)
    }
}
