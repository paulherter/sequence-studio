import Foundation
import Testing
@testable import SSAudioFX

@Suite struct DenoiserTests {
    @Test func noiseIsAttenuated() throws {
        let n = 48000 * 2
        let noise = Sig.lowNoise(amplitude: 0.05, count: n)
        let d = try RNNoiseDenoiser(channelCount: 1, sampleRate: 48000)
        let out = d.process([noise])[0]
        #expect(out.count == n)
        let tail = 48000..<n
        let rin = Sig.rms(noise[tail]), rout = Sig.rms(out[tail])
        #expect(rout < rin * 0.1, "in \(rin) out \(rout)")
    }

    @Test func silenceStaysSilent() throws {
        let d = try RNNoiseDenoiser(channelCount: 2, sampleRate: 48000)
        let out = d.process(Array(repeating: [Float](repeating: 0, count: 10000), count: 2))
        for c in out { #expect(c.allSatisfy { abs($0) < 1e-4 }) }
    }

    @Test func chunkingMatchesOneShot() throws {
        let n = 48000
        let x = [Sig.noise(amplitude: 0.1, count: n, seed: 3), Sig.noise(amplitude: 0.1, count: n, seed: 4)]
        let one = try RNNoiseDenoiser(channelCount: 2, sampleRate: 48000).process(x)
        let d = try RNNoiseDenoiser(channelCount: 2, sampleRate: 48000)
        let parts = Sig.chunked(x, sizes: [1, 479, 480, 481, 100, 4097, 3]).map { d.process($0) }
        let joined = Sig.concat(parts, channels: 2)
        #expect(joined == one)
    }

    @Test func mixZeroIsDelayedDry() throws {
        let x = [Sig.noise(amplitude: 0.1, count: 2000)]
        let d = try RNNoiseDenoiser(channelCount: 1, sampleRate: 48000)
        d.mix = 0
        let out = d.process(x)[0]
        let lat = RNNoiseDenoiser.latencySamples
        #expect(out[..<lat].allSatisfy { $0 == 0 })
        for i in lat..<2000 { #expect(abs(out[i] - x[0][i - lat]) < 1e-6) }
    }

    @Test func flushReturnsTail() throws {
        let x = [Sig.noise(amplitude: 0.1, count: 1000)]
        let d = try RNNoiseDenoiser(channelCount: 1, sampleRate: 48000)
        let a = d.process(x)[0]
        let b = d.flush()[0]
        #expect(a.count + b.count == 1000 + RNNoiseDenoiser.latencySamples)
    }

    @Test func rejectsWrongRate() {
        #expect(throws: AudioFXError.self) { try RNNoiseDenoiser(channelCount: 1, sampleRate: 44100) }
    }
}
