import Foundation
import SQCore
import Testing
@testable import SQAudioFX

@Suite struct PipelineTests {
    @Test func offPresetOnlyAppliesGain() throws {
        var vol = VolumeAutomation(staticDB: -6.0206)
        vol.pan = nil
        var p = try OfflineAudioFX(volume: vol, preset: .off, sampleRate: 48000, channelCount: 2)
        let x = Sig.sine(freq: 1000, amplitudeDB: -10, seconds: 0.5)
        let r = p.render(x, start: .zero)
        #expect(r.channels[0].count == x[0].count)
        #expect(r.denoiseApplied == false)
        for i in stride(from: 0, to: x[0].count, by: 97) { #expect(abs(r.channels[0][i] - x[0][i] * 0.5) < 1e-4) }
    }

    @Test func voicePresetDenoisesAndKeepsLength() throws {
        var preset = TrackAudioPreset.voice
        preset.noiseReduction = 1
        preset.compressor.bypass = true
        var p = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: preset, sampleRate: 48000, channelCount: 1)
        let n = 48000 * 2
        let noise = Sig.lowNoise(amplitude: 0.05, count: n)
        let r = p.render([noise], start: .zero)
        #expect(r.denoiseApplied)
        #expect(r.channels[0].count == n)
        #expect(Sig.rms(r.channels[0][48000..<n]) < Sig.rms(noise[48000..<n]) * 0.5)
    }

    @Test func denoiseMixZeroIsInputExactlyAndOneIsWet() throws {
        var preset = TrackAudioPreset.off
        preset.noiseReduction = 1
        let x = [Sig.lowNoise(amplitude: 0.1, count: 20000)]
        var dry = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: preset, sampleRate: 48000, channelCount: 1)
        dry.denoiseMix = 0
        #expect(dry.render(x, start: .zero).channels == x)

        var wet = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: preset, sampleRate: 48000, channelCount: 1)
        wet.denoiseMix = 1
        let w = wet.render(x, start: .zero).channels
        let ref = try RNNoiseDenoiser(channelCount: 1, sampleRate: 48000)
        let expected = Array((ref.process(x)[0] + ref.flush()[0]).dropFirst(RNNoiseDenoiser.latencySamples).prefix(20000))
        #expect(w[0] == expected)

        var half = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: preset, sampleRate: 48000, channelCount: 1)
        half.denoiseMix = 0.5
        let h = half.render(x, start: .zero).channels[0]
        for i in stride(from: 0, to: 20000, by: 131) { #expect(abs(h[i] - (x[0][i] + w[0][i]) / 2) < 1e-6) }
    }

    @Test func renderCompensatesLatency() throws {
        var preset = TrackAudioPreset.off
        preset.noiseReduction = 1
        var p = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: preset, sampleRate: 48000, channelCount: 1)
        p.denoiseMix = 0
        let x = [Sig.noise(amplitude: 0.3, count: 5000)]
        let r = p.render(x, start: .zero)
        for i in 0..<5000 { #expect(abs(r.channels[0][i] - x[0][i]) < 1e-6) }
    }

    @Test func compressorReducesLoudPeaksAboveThreshold() throws {
        var preset = TrackAudioPreset.off
        preset.compressor = .neutral
        preset.compressor.bypass = false
        for i in 0..<4 { preset.compressor.bands[i].thresholdDB = -30; preset.compressor.bands[i].ratio = 4
            preset.compressor.bands[i].attackMs = 1; preset.compressor.bands[i].releaseMs = 50 }
        var p = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: preset, sampleRate: 48000, channelCount: 1)
        let x = Sig.sine(freq: 440, amplitudeDB: -6, seconds: 1, channels: 1)
        let r = p.render(x, start: .zero)
        let inR = Sig.rms(x[0][24000...]), outR = Sig.rms(r.channels[0][24000...])
        #expect(outR < inR * 0.6)
    }

    @Test func gainComesAfterCompressor() throws {
        // Compressor sees the un-gained signal: +20 dB gain must not change what it does.
        var preset = TrackAudioPreset.off
        preset.compressor = .neutral
        preset.compressor.bypass = false
        for i in 0..<4 { preset.compressor.bands[i].thresholdDB = -30; preset.compressor.bands[i].ratio = 4
            preset.compressor.bands[i].attackMs = 1; preset.compressor.bands[i].releaseMs = 50 }
        let x = Sig.sine(freq: 440, amplitudeDB: -10, seconds: 1, channels: 1)
        var a = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: preset, sampleRate: 48000, channelCount: 1)
        var b = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 20), preset: preset, sampleRate: 48000, channelCount: 1)
        let ya = a.render(x, start: .zero).channels[0], yb = b.render(x, start: .zero).channels[0]
        let d = Sig.db(Sig.amplitude(yb[24000...], freq: 440)) - Sig.db(Sig.amplitude(ya[24000...], freq: 440))
        #expect(abs(d - 20) < 0.05)
    }

    @Test func volumeAutomationUsesStartTime() throws {
        var t = KeyframeTrack<Double>()
        t.insert(Keyframe(time: .zero, value: 0))
        t.insert(Keyframe(time: Time(2, 1), value: -20))
        var p = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0, track: t), preset: .off, sampleRate: 48000, channelCount: 1)
        let r = p.render([[Float](repeating: 1, count: 100)], start: Time(1, 1))
        #expect(abs(20 * log10(Double(r.channels[0][0])) + 10) < 0.05)
    }

    @Test func volumeAutomationAlignedWithDenoiseLatency() throws {
        // Gain last: a keyframed ramp must land on the compensated (input-aligned) samples.
        var t = KeyframeTrack<Double>()
        t.insert(Keyframe(time: .zero, value: 0))
        t.insert(Keyframe(time: Time(1, 1), value: -20))
        var preset = TrackAudioPreset.off
        preset.noiseReduction = 1
        var p = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0, track: t), preset: preset, sampleRate: 48000, channelCount: 1)
        p.denoiseMix = 0
        let r = p.render([[Float](repeating: 0.5, count: 48000)], start: .zero)
        #expect(abs(Double(r.channels[0][24000]) - 0.5 * pow(10, -10.0 / 20)) < 1e-4)
        #expect(abs(Double(r.channels[0][0]) - 0.5) < 1e-6)
    }

    @Test func streamingMatchesRender48k() throws {
        let preset = TrackAudioPreset.voice
        let x = [Sig.lowNoise(amplitude: 0.1, count: 30000)]
        var one = try OfflineAudioFX(volume: VolumeAutomation(staticDB: -3), preset: preset, sampleRate: 48000, channelCount: 1)
        let ref = one.render(x, start: .zero).channels
        var s = try OfflineAudioFX(volume: VolumeAutomation(staticDB: -3), preset: preset, sampleRate: 48000, channelCount: 1)
        var pos = Time.zero
        var parts: [[[Float]]] = []
        for c in Sig.chunked(x, sizes: [1000, 333, 4096]) {
            parts.append(s.process(c, start: pos)); pos += Time(Int64(c[0].count), 48000)
        }
        parts.append(s.flushTail(start: pos))
        let out = Array(Sig.concat(parts, channels: 1)[0].dropFirst(s.latencySamples).prefix(30000))
        #expect(out.count == 30000)
        for i in 0..<30000 { #expect(abs(out[i] - ref[0][i]) < 1e-5) }
    }
}
