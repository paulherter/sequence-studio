import Foundation
import SQCore
import Testing
@testable import SQAudioFX

@Suite struct CreatorFXTests {
    private func rmsDB(_ x: ArraySlice<Float>) -> Double { 20 * log10(max(1e-9, Sig.rms(x))) }

    @Test func gateSilencesQuietNoiseAndKeepsLoudSignal() {
        let n = 48000
        var tone = Sig.sine(freq: 300, amplitudeDB: -10, seconds: 0.5)
        let noise = Sig.noise(amplitude: 0.001, count: n / 2)
        for c in 0..<2 { tone[c].append(contentsOf: noise) }
        var gate = NoiseGate(settings: NoiseGateSettings(enabled: true, thresholdDB: -40, reductionDB: 40,
                                                         attackMs: 1, holdMs: 20, releaseMs: 30), sampleRate: 48000)
        var out = tone
        gate.process(&out)
        #expect(abs(rmsDB(out[0][4800..<20000]) - rmsDB(tone[0][4800..<20000])) < 0.2)
        #expect(rmsDB(out[0][36000..<48000]) < rmsDB(tone[0][36000..<48000]) - 30)
    }

    @Test func gateIsChunkInvariant() {
        let x = Sig.lowNoise(amplitude: 0.05, count: 24000)
        let sig = [x, x]
        let s = NoiseGateSettings(enabled: true, thresholdDB: -30)
        var a = NoiseGate(settings: s, sampleRate: 48000), b = a
        var whole = sig
        a.process(&whole)
        var parts: [[Float]] = [[], []]
        for chunk in Sig.chunked(sig, sizes: [1, 7, 480, 133]) {
            var c = chunk
            b.process(&c)
            for k in 0..<2 { parts[k].append(contentsOf: c[k]) }
        }
        #expect(parts == whole)
    }

    @Test func disabledGateAndSaturationAreTransparent() {
        let x = Sig.sine(freq: 440, amplitudeDB: -6, seconds: 0.1)
        var y = x
        var g = NoiseGate(settings: .off, sampleRate: 48000); g.process(&y)
        var s = Saturator(settings: .off); s.process(&y)
        #expect(y == x)
    }

    @Test func saturationKeepsPeaksAndMixZeroIsDry() {
        let x = Sig.sine(freq: 440, amplitudeDB: -1, seconds: 0.2)
        var wet = x
        Saturator(settings: SaturationSettings(enabled: true, driveDB: 12, mix: 1)).process(&wet)
        let peakOut = wet[0].map(abs).max()!
        #expect(peakOut <= 1.0001)
        #expect(Sig.rms(wet[0][...]) > Sig.rms(x[0][...]))
        var dry = x
        Saturator(settings: SaturationSettings(enabled: true, driveDB: 12, mix: 0)).process(&dry)
        #expect(dry == x)
    }

    @Test func presetDecodesOldJSONWithoutNewFields() throws {
        var p = TrackAudioPreset.voice
        p.gate = .off; p.saturation = .off
        // Old files carry no gate/saturation keys.
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        obj.removeValue(forKey: "gate"); obj.removeValue(forKey: "saturation")
        let old = try JSONDecoder().decode(TrackAudioPreset.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.gate == .off && old.saturation == .off && old.noiseReduction == p.noiseReduction)
        var q = p; q.gate.enabled = true; q.saturation.enabled = true
        let back = try JSONDecoder().decode(TrackAudioPreset.self, from: JSONEncoder().encode(q))
        #expect(back == q)
    }

    @Test func offlineChainAppliesGate() throws {
        var preset = TrackAudioPreset(id: "x", name: "x", compressor: .neutral, noiseReduction: 0)
        preset.gate = NoiseGateSettings(enabled: true, thresholdDB: -30, reductionDB: 60, attackMs: 1, holdMs: 0, releaseMs: 10)
        let quiet = [Sig.noise(amplitude: 0.002, count: 24000)]
        var fx = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: preset, sampleRate: 48000, channelCount: 1)
        let out = fx.render(quiet, start: Time(0, 1)).channels
        #expect(Sig.rms(out[0][12000...]) < Sig.rms(quiet[0][12000...]) * 0.01)
    }

    @Test func realtimeMatchesOfflineWithGateAndSaturation() throws {
        var preset = TrackAudioPreset(id: "x", name: "x", compressor: .neutral, noiseReduction: 0)
        preset.gate = NoiseGateSettings(enabled: true, thresholdDB: -35)
        preset.saturation = SaturationSettings(enabled: true, driveDB: 9, mix: 0.7)
        var sig = Sig.sine(freq: 220, amplitudeDB: -8, seconds: 0.3)
        let nz = Sig.noise(amplitude: 0.003, count: 9600)
        for c in 0..<2 { sig[c].append(contentsOf: nz) }
        var off = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: preset, sampleRate: 48000, channelCount: 2)
        let want = off.render(sig, start: Time(0, 1)).channels
        let rt = try RealtimeAudioFX(preset: preset, volume: VolumeAutomation(staticDB: 0), channelCount: 2, maxFrames: 512, denoiser: false)
        let n = sig[0].count
        let bufs = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 512) }
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        for c in 0..<2 { ptrs[c] = bufs[c] }
        defer { bufs.forEach { $0.deallocate() }; ptrs.deallocate() }
        var pos = 0
        var d: Float = 0
        while pos < n {
            let m = min(300, n - pos)
            for c in 0..<2 { for i in 0..<m { bufs[c][i] = sig[c][pos + i] } }
            rt.process(ptrs, frameCount: m, timelineSample: Int64(pos))
            for c in 0..<2 { for i in 0..<m { d = max(d, abs(bufs[c][i] - want[c][pos + i])) } }
            pos += m
        }
        #expect(d < 1e-5)
    }
}

/// Gate envelope timing on a synthetic burst (offline buffers only). A level step between a loud and a quiet DC value makes
/// the output / input ratio the gate gain, so the times are read straight off the samples.
@Suite struct NoiseGateEnvelopeTests {
    private let fs = 48000.0
    private let loud: Float = 0.5, quiet: Float = 0.001   // -6 dB and -60 dB; threshold -40 dB

    private func settings(attack: Double = 1, hold: Double = 0, release: Double = 100) -> NoiseGateSettings {
        NoiseGateSettings(enabled: true, thresholdDB: -40, reductionDB: 40, attackMs: attack, holdMs: hold, releaseMs: release)
    }

    /// Gain per sample for `loudMs` of loud signal followed by `quietMs` of quiet signal, the gate starting open.
    private func closingGains(_ s: NoiseGateSettings, loudMs: Double = 100, quietMs: Double = 700) -> [Float] {
        let a = Int(loudMs / 1000 * fs), b = Int(quietMs / 1000 * fs)
        var buf = [[Float](repeating: loud, count: a) + [Float](repeating: quiet, count: b)]
        var gate = NoiseGate(settings: s, sampleRate: fs)
        gate.process(&buf)
        return (0..<(a + b)).map { i in buf[0][i] / (i < a ? loud : quiet) }
    }

    private func firstIndex(_ g: [Float], from: Int, where p: (Float) -> Bool) -> Int {
        (from..<g.count).first { p(g[$0]) } ?? g.count
    }

    @Test func holdDelaysTheClosingByItsTime() {
        let start = Int(0.1 * fs)
        let t0 = firstIndex(closingGains(settings(hold: 0)), from: start) { $0 < 0.9 }
        let g100 = closingGains(settings(hold: 100))
        let t100 = firstIndex(g100, from: start) { $0 < 0.9 }
        let ms = Double(t100 - t0) / fs * 1000
        #expect(abs(ms - 100) < 1.5)
        // Held means the gain stays at 1 until then.
        #expect(g100[t0 + Int(0.05 * fs)] == 1)
    }

    @Test func releaseGlidesAtItsTime() {
        for rel in [30.0, 120.0] {
            let g = closingGains(settings(release: rel), quietMs: 900)
            let begin = firstIndex(g, from: Int(0.1 * fs)) { $0 < 0.999 }
            let end = firstIndex(g, from: begin) { $0 < 0.01 + 0.99 * 0.3679 }
            let ms = Double(end - begin) / fs * 1000
            #expect(abs(ms - rel) < rel * 0.1 + 0.5, "release \(rel): \(ms)")
        }
    }

    @Test func attackGlidesAtItsTime() {
        for atk in [5.0, 40.0] {
            let quietN = Int(0.5 * fs), loudN = Int(0.3 * fs)
            var buf = [[Float](repeating: quiet, count: quietN) + [Float](repeating: loud, count: loudN)]
            var gate = NoiseGate(settings: settings(attack: atk, release: 5), sampleRate: fs)
            gate.process(&buf)
            let g = (quietN..<(quietN + loudN)).map { buf[0][$0] / loud }
            // 63.2 % of the way from the floor (0.01) to 1.
            let n = g.firstIndex { $0 >= 0.01 + 0.99 * 0.632 } ?? g.count
            let ms = Double(n) / fs * 1000
            #expect(abs(ms - atk) < atk * 0.1 + 0.5, "attack \(atk): \(ms)")
        }
    }

    @Test func changingTheTimesMidStreamDoesNotJumpTheGain() {
        var gate = NoiseGate(settings: settings(attack: 50, hold: 0, release: 200), sampleRate: fs)
        var a = [[Float](repeating: quiet, count: 4800)]
        gate.process(&a)
        let cfg = NoiseGate.Config(settings: settings(attack: 1, hold: 300, release: 5), sampleRate: fs)
        gate.apply(cfg)
        var b = [[Float](repeating: quiet, count: 480)]
        gate.process(&b)
        let before = a[0].last! / quiet, after = b[0].first! / quiet
        #expect(abs(after - before) < 0.02)
    }
}
