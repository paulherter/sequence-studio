import Foundation
import Testing
import SQCore
@testable import SQAudioFX

// Enhance Speech: Low Cut -> RNNoise -> De-Reverb -> dialogue EQ -> Dialogue Leveler in one stage, driven by Amount + Preset.

private func run(_ v: AudioEnhanceSpeechValues, _ x: [[Float]], enabled: Bool = true, sizes: [Int] = [480]) throws -> [[Float]] {
    let s = AudioFXSlot(id: UUID(), kind: ClipEffect.audioEnhanceSpeechKind)
    let chain = try ClipAudioFXChain(layout: [s], channelCount: x.count, maxFrames: 4096)
    var out: [[[Float]]] = []
    for part in Sig.chunked(x, sizes: sizes) {
        var b = part
        chain.process(&b, steps: [AudioFXStep(id: s.id, enabled: enabled, stage: .enhanceSpeech(v))])
        out.append(b)
    }
    return Sig.concat(out, channels: x.count)
}

private let lat = AudioEnhanceSpeechValues.latencySamples

/// Gain in dB of a steady tone after the stage (compensated for the delay, measured after 0.5 s).
private func toneGainDB(_ hz: Double, _ v: AudioEnhanceSpeechValues, enabled: Bool = true) throws -> Double {
    let x = Sig.sine(freq: hz, amplitudeDB: -20, seconds: 1.5, channels: 1)
    let y = try run(v, x, enabled: enabled)[0]
    let n = 48_000
    return Sig.db(Sig.amplitude(y[(24_000 + lat)..<(n + lat)], freq: hz) / Sig.amplitude(x[0][24_000..<n], freq: hz))
}

/// Speech-like test signal: a 120-180 Hz glottal harmonic series shaped by two formants, in 4 Hz syllables (on 150 ms,
/// off 100 ms), with slow pitch movement. Returns the signal and a mask of the voiced samples.
private func voice(seconds: Double, levelDB: Double = -20) -> (x: [Float], voiced: [Bool]) {
    let fs = 48_000.0, n = Int(seconds * fs)
    var x = [Float](repeating: 0, count: n), voiced = [Bool](repeating: false, count: n)
    var phase = 0.0
    for i in 0..<n {
        let t = Double(i) / fs
        let f0 = 150 + 30 * sin(2 * .pi * 0.7 * t)
        phase += 2 * .pi * f0 / fs
        let syl = t.truncatingRemainder(dividingBy: 0.25)
        let on = syl < 0.15
        voiced[i] = syl > 0.02 && syl < 0.13
        guard on else { continue }
        let env = sin(.pi * syl / 0.15)
        var s = 0.0
        for h in 1...30 {
            let hf = f0 * Double(h)
            if hf > 8_000 { break }
            // Formants near 600 Hz and 1.8 kHz, 1/h glottal roll-off.
            let w = 1 / Double(h) * (1 + 3 * exp(-pow((hf - 600) / 200, 2)) + 2 * exp(-pow((hf - 1_800) / 300, 2)))
            s += w * sin(Double(h) * phase)
        }
        x[i] = Float(s * env)
    }
    let rms = Sig.rms(x[...]) * sqrt(Double(n) / Double(voiced.filter { $0 }.count))
    let g = Float(pow(10, levelDB / 20) / max(rms, 1e-9))
    return (x.map { $0 * g }, voiced)
}

@Suite struct EnhanceSpeechTests {
    @Test func latencyIsDeclaredAndExact() throws {
        #expect(RNNoiseDenoiser.latencySamples + AudioDeReverbValues.latencySamples == lat)
        let chain = try ClipAudioFXChain(layout: [AudioFXSlot(id: UUID(), kind: ClipEffect.audioEnhanceSpeechKind)], channelCount: 2, maxFrames: 512)
        #expect(chain.latencySamples == lat)
        // A 1 kHz tone comes out exactly `lat` samples later (zero crossing phase check via the single-bin DFT).
        let x = Sig.sine(freq: 1_000, amplitudeDB: -20, seconds: 1, channels: 1)
        let y = try run(AudioEnhanceSpeechValues(amount: 0, preset: 0), x)[0]
        var err = 0.0
        for i in 24_000..<40_000 { err = max(err, Double(abs(y[i + lat] - x[0][i]))) }
        #expect(err < 0.01, "max error \(err)")       // -20 dBFS tone = 0.1 peak: within 20 dB
    }

    @Test func amountZeroAndDisabledAreTransparent() throws {
        for hz in [200.0, 1_000, 4_000, 10_000] {
            let g0 = try toneGainDB(hz, AudioEnhanceSpeechValues(amount: 0, preset: 0))
            #expect(abs(g0) < 0.3, "\(hz) Hz at 0 %: \(g0) dB")
            let off = try toneGainDB(hz, AudioEnhanceSpeechValues(amount: 1, preset: 0), enabled: false)
            #expect(abs(off) < 0.3, "\(hz) Hz disabled: \(off) dB")
        }
    }

    @Test func rumbleIsCut() throws {
        let full = AudioEnhanceSpeechValues(amount: 1, preset: 0)
        let rumble = try toneGainDB(30, full)
        #expect(rumble < -15, "30 Hz \(rumble) dB")
    }

    @Test func dialogueEQCurve() {
        // The filters alone (the denoiser and leveler react to steady tones, so the curve is measured without them).
        func gain(_ hz: Double, _ amount: Double) -> Double {
            let st = EnhanceSpeechStage(sampleRate: 48_000, channels: 1)
            defer { st.free() }
            var x = Sig.mono(hz, amplitudeDB: -20, seconds: 0.5)
            let ref = Sig.amplitude(x[12_000...], freq: hz)
            x.withUnsafeMutableBufferPointer { p in
                var ptr: UnsafeMutablePointer<Float>? = p.baseAddress
                withUnsafeMutablePointer(to: &ptr) { pp in
                    pp.withMemoryRebound(to: UnsafeMutablePointer<Float>.self, capacity: 1) {
                        st.filtersOnly($0, channels: 1, frames: p.count, recipe: AudioEnhanceSpeechValues(amount: amount, preset: 0).recipe)
                    }
                }
            }
            return Sig.db(Sig.amplitude(x[12_000...], freq: hz) / ref)
        }
        let full = AudioEnhanceSpeechValues(amount: 1, preset: 0).recipe
        #expect(abs(gain(3_500, 1) - full.presenceDB) < 0.8, "presence \(gain(3_500, 1))")
        #expect(abs(gain(300, 1) - full.mudDB) < 0.8, "mud \(gain(300, 1))")
        #expect(gain(30, 1) < -25, "rumble \(gain(30, 1))")
        #expect(gain(1_000, 1) > -1.5 && gain(1_000, 1) < 1.5)
        for hz in [100.0, 300, 3_500, 10_000] { #expect(abs(gain(hz, 0)) < 0.2, "\(hz) Hz at 0 %") }
    }

    @Test func noiseInPausesIsReducedAndVoiceKept() throws {
        let seconds = 4.0
        let (v, voiced) = voice(seconds: seconds)
        let noise = Sig.lowNoise(amplitude: 0.02, count: v.count, seed: 7)
        let x = [zip(v, noise).map { $0 + $1 }]
        func levels(_ amount: Double) throws -> (pause: Double, voice: Double) {
            let y = try run(AudioEnhanceSpeechValues(amount: amount, preset: 1), x)[0]
            var p = 0.0, pc = 0, s = 0.0, sc = 0
            for i in 48_000..<(v.count - lat) {         // skip the first second (denoiser and leveler settle)
                let o = Double(y[i + lat])
                if voiced[i] { s += o * o; sc += 1 } else if !voiced[max(0, i - 2_400)] && !voiced[min(v.count - 1, i + 2_400)] && v[i] == 0 { p += o * o; pc += 1 }
            }
            return (Sig.db((p / Double(max(pc, 1))).squareRoot()), Sig.db((s / Double(max(sc, 1))).squareRoot()))
        }
        let dry = try levels(0), half = try levels(0.5), full = try levels(1)
        // Pauses: the noise goes well down, more with more amount.
        #expect(full.pause < dry.pause - 10, "pause \(dry.pause) -> \(full.pause) dB")
        #expect(half.pause < dry.pause - 3 && half.pause > full.pause, "half \(half.pause)")
        // Voice: the speech level stays (within the leveler's few dB), so the speech-to-noise gap grows.
        #expect(abs(full.voice - dry.voice) < 6, "voice \(dry.voice) -> \(full.voice) dB")
        #expect((full.voice - full.pause) > (dry.voice - dry.pause) + 8)
    }

    @Test func blockSizeDoesNotChangeTheSound() throws {
        let (v, _) = voice(seconds: 1)
        let x = [zip(v, Sig.lowNoise(amplitude: 0.02, count: v.count, seed: 3)).map { $0 + $1 }]
        let a = try run(AudioEnhanceSpeechValues(amount: 0.8, preset: 2), x, sizes: [480])
        let b = try run(AudioEnhanceSpeechValues(amount: 0.8, preset: 2), x, sizes: [1, 127, 480, 1_024, 333])
        var err: Float = 0
        for i in a[0].indices { err = max(err, abs(a[0][i] - b[0][i])) }
        #expect(err < 1e-4, "\(err)")
    }

    @Test func silenceStaysSilentAndFinite() throws {
        let x = [[Float](repeating: 0, count: 24_000), [Float](repeating: 0, count: 24_000)]
        let y = try run(AudioEnhanceSpeechValues(amount: 1, preset: 0), x)
        for c in y { #expect(c.allSatisfy { $0.isFinite && abs($0) < 1e-4 }) }
    }
}
