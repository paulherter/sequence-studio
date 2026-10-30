import Foundation
import SQCore
import Testing
@testable import SQAudioFX

@Suite struct RoleChainTests {
    /// Speech-like synthetic: harmonic pitch glide (12 harmonics) with a syllable envelope, plus a little hiss.
    static func voice(seconds: Double, rate: Int = 48000, peakDB: Double = -3) -> [Float] {
        let n = Int(seconds * Double(rate))
        let noise = Sig.noise(amplitude: 1, count: n, seed: 7)
        var phase = 0.0
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            let f0 = 140 + 30 * sin(2 * .pi * 0.7 * t)
            phase += 2 * .pi * f0 / Double(rate)
            var s = 0.0
            for h in 1...12 { s += sin(Double(h) * phase) / Double(h) }
            let env = 0.15 + 0.85 * max(0, sin(2 * .pi * 3.5 * t))
            out[i] = Float(s * env * 0.3 + Double(noise[i]) * 0.003)
        }
        let a = Float(pow(10, peakDB / 20)) / (out.map { abs($0) }.max() ?? 1)
        return out.map { $0 * a }
    }

    @Test func voiceLandsAtMinus14WithTruePeakUnderMinus1() throws {
        let mono = Self.voice(seconds: 12)
        let out = try RoleChain.render([mono], role: .dialogue, sampleRate: 48000)
        #expect(out.count == 2)
        #expect(out[0].count == mono.count)
        let m = RoleChain.measure(out, sampleRate: 48000)
        #expect(abs(m.lufs - -14) <= 0.4, "lufs \(m.lufs)")
        #expect(m.truePeakDB <= -1, "tp \(m.truePeakDB)")
    }

    @Test func hotVoiceStillRespectsCeiling() throws {
        let x = Self.voice(seconds: 8, peakDB: -0.1)
        let out = try RoleChain.render([x, x], role: .dialogue, sampleRate: 48000)
        let m = RoleChain.measure(out, sampleRate: 48000)
        #expect(abs(m.lufs - -14) <= 0.4, "lufs \(m.lufs)")
        #expect(m.truePeakDB <= -1, "tp \(m.truePeakDB)")
    }

    @Test func musicSitsSixDbUnderVoice() throws {
        let tone = Sig.sine(freq: 440, amplitudeDB: -12, seconds: 6)
        let out = try RoleChain.render(tone, role: .music, sampleRate: 48000)
        let m = RoleChain.measure(out, sampleRate: 48000)
        #expect(abs(m.lufs - -20) <= 0.4, "lufs \(m.lufs)")
        #expect(m.truePeakDB <= -1)
    }

    @Test func monoBecomesIdenticalStereo() {
        #expect(RoleChain.monoToStereo([[0.1, 0.2]]) == [[0.1, 0.2], [0.1, 0.2]])
        #expect(RoleChain.monoToStereo([[1], [2]]) == [[1], [2]])
    }

    /// Amplitude of the `freq` component (correlation with sin/cos over the second half).
    static func component(_ x: [Float], freq: Double, rate: Int = 48000) -> Double {
        var a = 0.0, b = 0.0
        let from = x.count / 2
        for i in from..<x.count {
            let ph = 2 * Double.pi * freq * Double(i) / Double(rate)
            a += Double(x[i]) * sin(ph); b += Double(x[i]) * cos(ph)
        }
        return 2 * (a * a + b * b).squareRoot() / Double(x.count - from)
    }

    @Test func deEsserCrossoverIsFlatInLevel() {
        for rate in [44100, 48000, 96000] {
            for f in [200.0, 1000, 3000, 4800, 5200, 8000] {
                var buf = Sig.sine(freq: f, amplitudeDB: -12, seconds: 1, rate: rate, channels: 1)
                let ref = Self.component(buf[0], freq: f, rate: rate)
                var d = DeEsser(sampleRate: rate, channelCount: 1, ratioThreshold: 1000)   // never triggers
                d.process(&buf)
                let ratio = Self.component(buf[0], freq: f, rate: rate) / ref
                #expect(abs(20 * log10(ratio)) < 0.1, "\(rate) Hz \(f): \(ratio)")
            }
        }
    }

    @Test func deEsserLeavesSpeechAlone() {
        let v = Self.voice(seconds: 4)
        var buf = [v]
        var d = DeEsser(sampleRate: 48000, channelCount: 1)
        d.process(&buf)
        let dB = 20 * log10(Sig.rms(buf[0][24000...]) / Sig.rms(v[24000...]))
        #expect(abs(dB) < 0.2, "\(dB)")
    }

    @Test func deEsserReducesSibilanceByThreeToTenDb() {
        let low = Sig.sine(freq: 300, amplitudeDB: -12, seconds: 1, channels: 1)[0]
        let hiss = Sig.sine(freq: 7000, amplitudeDB: -12, seconds: 1, channels: 1)[0]
        var buf = [zip(low, hiss).map { $0 + $1 }]
        var d = DeEsser(sampleRate: 48000, channelCount: 1)
        d.process(&buf)
        let sibDB = 20 * log10(Self.component(buf[0], freq: 7000) / Self.component(hiss, freq: 7000))
        let lowDB = 20 * log10(Self.component(buf[0], freq: 300) / Self.component(low, freq: 300))
        #expect(sibDB < -2.5 && sibDB > -10.5, "sib \(sibDB)")
        #expect(abs(lowDB) < 0.2, "low \(lowDB)")
    }

    @Test func deEsserStateContinuesAcrossBuffers() {
        let low = Sig.sine(freq: 300, amplitudeDB: -12, seconds: 1, channels: 1)[0]
        let hiss = Sig.sine(freq: 7000, amplitudeDB: -12, seconds: 1, channels: 1)[0]
        let whole = zip(low, hiss).map { $0 + $1 }
        var a = [whole]
        var d1 = DeEsser(sampleRate: 48000, channelCount: 1)
        d1.process(&a)
        var d2 = DeEsser(sampleRate: 48000, channelCount: 1)
        var out: [Float] = []
        var pos = 0
        for size in [1, 77, 1000, 4096, 333] {
            guard pos < whole.count else { break }
            var chunk = [Array(whole[pos..<min(whole.count, pos + size)])]
            d2.process(&chunk); out += chunk[0]; pos += size
        }
        var rest = [Array(whole[pos...])]
        d2.process(&rest); out += rest[0]
        #expect(out == a[0])
    }

    @Test func otherSampleRatesAndSilence() throws {
        for rate in [44100, 96000] {
            let out = try RoleChain.render([Self.voice(seconds: 8, rate: rate)], role: .dialogue, sampleRate: rate)
            let m = RoleChain.measure(out, sampleRate: rate)
            #expect(abs(m.lufs - -14) <= 0.4 && m.truePeakDB <= -1, "\(rate): \(m)")
        }
        let silent = try RoleChain.render([[Float](repeating: 0, count: 48000)], role: .dialogue, sampleRate: 48000)
        #expect(silent.count == 2 && silent[0].allSatisfy { $0 == 0 })
    }

    @Test func shortLoudClipStaysUnderCeiling() throws {
        let click = (Self.voice(seconds: 0.25, peakDB: 0)).map { $0 * 1.0 }
        for role in AudioTag.allCases {
            let out = try RoleChain.render([click], role: role, sampleRate: 48000)
            #expect(RoleChain.measure(out, sampleRate: 48000).truePeakDB <= -1)
        }
        let direct = RoleChain.finish([click, click], targetLUFS: -14, sampleRate: 48000, ceilingDB: -1)
        #expect(RoleChain.measure(direct, sampleRate: 48000).truePeakDB <= -1)
    }

    @Test func boostIsCapped() {
        let quiet = Sig.sine(freq: 440, amplitudeDB: -50, seconds: 3)
        let out = RoleChain.finish(quiet, targetLUFS: -14, sampleRate: 48000, ceilingDB: -1)
        let gain = RoleChain.measure(out, sampleRate: 48000).lufs - RoleChain.measure(quiet, sampleRate: 48000).lufs
        #expect(gain <= RoleChain.maxBoostDB + 0.1, "\(gain)")
    }

    @Test func threeAndSixChannelsAreLimited() {
        let v = Self.voice(seconds: 3, peakDB: 0)
        for count in [3, 4, 6] {
            let out = RoleChain.finish(Array(repeating: v, count: count), targetLUFS: -14, sampleRate: 48000, ceilingDB: -1)
            #expect(out.count == count)
            #expect(RoleChain.measure(out, sampleRate: 48000).truePeakDB <= -1, "\(count)")
        }
    }

    @Test func onlyTheVoiceRoleDeEsses() {
        #expect(TrackAudioPreset.forRole(.dialogue).deEss)
        #expect(!TrackAudioPreset.forRole(.music).deEss)
        #expect(!TrackAudioPreset.forRole(.sfx).deEss)
    }

    @Test func presetWithoutDeEssKeyDecodesOff() throws {
        let data = try JSONEncoder().encode(TrackAudioPreset.voice)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "deEss")
        let old = try JSONDecoder().decode(TrackAudioPreset.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(!old.deEss)
        let round = try JSONDecoder().decode(TrackAudioPreset.self, from: JSONEncoder().encode(TrackAudioPreset.forRole(.dialogue)))
        #expect(round.deEss)
    }

    /// The role preset (what playback and export run per track) tames sibilance; the music preset does not.
    @Test func rolePresetDeEssesInTheSharedFXPath() throws {
        let n = 48000
        let hiss = Sig.noise(amplitude: 0.05, count: n, seed: 3)
        let sib: [Float] = (0..<n).map { i in
            Float(0.2 * sin(2 * Double.pi * 7000 * Double(i) / 48000)) * (i % 24000 < 12000 ? 1 : 0) + hiss[i] * 0
        }
        func level(_ preset: TrackAudioPreset) throws -> Double {
            var p = preset; p.noiseReduction = 0
            var fx = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: p, sampleRate: 48000, channelCount: 1)
            let y = fx.render([sib], start: .zero).channels[0]
            return Self.component(Array(y[6000..<12000]), freq: 7000)
        }
        let voice = try level(.forRole(.dialogue))
        var noDe = TrackAudioPreset.forRole(.dialogue); noDe.deEss = false
        let plain = try level(noDe)
        #expect(voice < plain * 0.8, "voice \(voice) plain \(plain)")
    }
}
