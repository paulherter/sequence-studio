import Foundation
import Testing
@testable import SSAudioFX

@Suite struct ResampleTests {
    // 96 kHz: the same one-pole noise sits at lower frequencies in Hz, which RNNoise attenuates less.
    @Test(arguments: [(44100, 0.2), (32000, 0.2), (96000, 0.5)])
    func denoisesNon48kAndKeepsLength(rate: Int, limit: Double) throws {
        var preset = TrackAudioPreset.off
        preset.noiseReduction = 1
        var p = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: preset, sampleRate: rate, channelCount: 1)
        let n = rate * 2
        let noise = Sig.lowNoise(amplitude: 0.05, count: n)
        let r = p.render([noise], start: .zero)
        #expect(r.denoiseApplied)
        #expect(r.channels[0].count == n)
        #expect(Sig.rms(r.channels[0][rate..<n]) < Sig.rms(noise[rate..<n]) * limit)
    }

    @Test func sineLevelPreserved441() throws {
        var preset = TrackAudioPreset.off
        preset.noiseReduction = 1
        var p = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: preset, sampleRate: 44100, channelCount: 1)
        p.denoiseMix = 0                                     // dry path still crosses both converters
        let x = Sig.sine(freq: 1000, amplitudeDB: -12, seconds: 1, rate: 44100, channels: 1)
        let y = p.render(x, start: .zero).channels[0]
        #expect(y.count == x[0].count)
        let a = Sig.db(Sig.amplitude(y[11025..<33075], freq: 1000, rate: 44100))
        #expect(abs(a + 12) < 0.1, "\(a)")
        // and time-aligned with the input
        var err = 0.0
        for i in 11025..<33075 { err = max(err, abs(Double(y[i] - x[0][i]))) }
        #expect(err < 0.01, "max error \(err)")
    }

    @Test func sineSurvivesWetDenoise441() throws {
        var preset = TrackAudioPreset.off
        preset.noiseReduction = 1
        var p = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: preset, sampleRate: 44100, channelCount: 1)
        // speech-like tone burst over quiet low noise: level must stay within a few dB
        let n = 44100 * 2
        var x = Sig.lowNoise(amplitude: 0.002, count: n)
        let tone = Sig.sine(freq: 440, amplitudeDB: -12, seconds: 2, rate: 44100, channels: 1)[0]
        for i in 0..<n { x[i] += tone[i] }
        let y = p.render([x], start: .zero).channels[0]
        let a = Sig.db(Sig.amplitude(y[44100..<88200], freq: 440, rate: 44100))
        #expect(abs(a + 12) < 3, "\(a)")
    }

    @Test func streamingChunksAt441() throws {
        var preset = TrackAudioPreset.off
        preset.noiseReduction = 1
        var p = try OfflineAudioFX(volume: VolumeAutomation(staticDB: 0), preset: preset, sampleRate: 44100, channelCount: 1)
        p.denoiseMix = 0
        let x = Sig.sine(freq: 1000, amplitudeDB: -12, seconds: 1, rate: 44100, channels: 1)
        for c in Sig.chunked(x, sizes: [1, 100, 441, 1024]) {
            #expect(p.process(c, start: .zero).first?.count == c[0].count)
        }
    }
}
