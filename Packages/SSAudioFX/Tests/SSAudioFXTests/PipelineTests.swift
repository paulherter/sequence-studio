import Foundation
import SSCore
import Testing
@testable import SSAudioFX

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
        var p = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: .voice, sampleRate: 48000, channelCount: 1)
        let n = 48000 * 2
        let noise = Sig.lowNoise(amplitude: 0.05, count: n)
        let r = p.render([noise], start: .zero)
        #expect(r.denoiseApplied)
        #expect(r.channels[0].count == n)
        #expect(Sig.rms(r.channels[0][48000..<n]) < Sig.rms(noise[48000..<n]) * 0.5)
    }

    @Test func renderCompensatesLatency() throws {
        var preset = TrackAudioPreset.off
        preset.noiseReduction = 0           // dry path through denoiser is still delayed internally
        var p = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: preset, sampleRate: 48000, channelCount: 1)
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

    @Test func volumeAutomationUsesStartTime() throws {
        var t = KeyframeTrack<Double>()
        t.insert(Keyframe(time: .zero, value: 0))
        t.insert(Keyframe(time: Time(2, 1), value: -20))
        var p = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0, track: t), preset: .off, sampleRate: 48000, channelCount: 1)
        let r = p.render([[Float](repeating: 1, count: 100)], start: Time(1, 1))
        #expect(abs(20 * log10(Double(r.channels[0][0])) + 10) < 0.05)
    }
}
