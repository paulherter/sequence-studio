import Foundation
import Testing
@testable import SSAudioFX

@Suite struct MultibandTests {
    static let xo = [100.0, 1000.0, 10000.0]

    /// Only `band` compresses (threshold -30 dB, ratio 4); the others are ratio 1.
    static func settings(band: Int, gainDB: Double = 0, attack: Double = 5, release: Double = 500) -> MultibandCompressorSettings {
        var s = MultibandCompressorSettings.neutral
        s.bypass = false
        s.crossoversHz = xo
        s.bands[band] = .init(thresholdDB: -30, ratio: 4, attackMs: attack, releaseMs: release, gainDB: gainDB)
        return s
    }

    static func run(_ s: MultibandCompressorSettings, _ x: [Float]) -> [Float] {
        var c = MultibandCompressor(settings: s, sampleRate: 48000, channels: 1)
        var b = [x]
        c.process(&b)
        return b[0]
    }

    // MARK: crossover

    @Test func recombinedBandsAreFlat() {
        var s = MultibandCompressorSettings.neutral
        s.bypass = false; s.crossoversHz = Self.xo          // ratio 1 everywhere: no compression
        for f in [30.0, 100, 316, 1000, 3000, 8000, 10000, 15000] {
            let x = Sig.mono(f, amplitudeDB: -12, seconds: 1)
            let y = Self.run(s, x)
            let a = Sig.db(Sig.amplitude(y[24000...], freq: f)) - Sig.db(Sig.amplitude(x[24000...], freq: f))
            #expect(abs(a) < 0.1, "\(f) Hz: \(a) dB")
        }
    }

    @Test func recombinedNoiseKeepsEnergy() {
        var s = MultibandCompressorSettings.neutral
        s.bypass = false; s.crossoversHz = Self.xo
        let x = Sig.noise(amplitude: 0.3, count: 96000)
        let y = Self.run(s, x)
        // Allpass sum: energy preserved; a bad (out-of-phase) recombination would notch it.
        let d = Sig.db(Sig.rms(y[4800...])) - Sig.db(Sig.rms(x[4800...]))
        #expect(abs(d) < 0.1, "\(d) dB")
    }

    // MARK: static curve

    @Test(arguments: [(0, 25.0), (1, 316.0), (2, 3000.0), (3, 20000.0)])
    func staticCurvePerBand(band: Int, freq: Double) {
        for (levelDB, expectedGR) in [(-10.0, 15.0), (-20.0, 7.5), (-40.0, 0.0)] {
            // release long enough to be flat over the period of a 25 Hz tone
            let s = Self.settings(band: band, gainDB: 2, release: 5000)
            let x = Sig.mono(freq, amplitudeDB: levelDB, seconds: 3)
            let y = Self.run(s, x)
            let outDB = Sig.db(Sig.amplitude(y[96000...], freq: freq))
            let expected = levelDB - expectedGR + 2
            #expect(abs(outDB - expected) < 0.75, "band \(band) in \(levelDB): out \(outDB) expected \(expected)")
        }
    }

    @Test func otherBandsAreUnaffected() {
        let s = Self.settings(band: 2)
        let loud = Sig.mono(3000, amplitudeDB: -10, seconds: 2)
        let quiet = Sig.mono(25, amplitudeDB: -40, seconds: 2)
        let mix = zip(loud, quiet).map { $0 + $1 }
        let y = Self.run(s, mix)
        let lowOut = Sig.db(Sig.amplitude(y[48000...], freq: 25)), lowIn = Sig.db(Sig.amplitude(quiet[48000...], freq: 25))
        #expect(abs(lowOut - lowIn) < 0.1, "\(lowOut - lowIn)")
        #expect(Sig.db(Sig.amplitude(y[48000...], freq: 3000)) < -10 - 10)       // the loud band is compressed
    }

    // MARK: ballistics

    /// Gain (dB) applied in a 1 ms window (3 whole periods of 3 kHz) starting at sample `at`, vs. input level.
    static func gainDB(_ y: [Float], at: Int, inputDB: Double) -> Double {
        Sig.db(Sig.amplitude(y[at..<at + 48], freq: 3000)) - inputDB
    }

    @Test func attackTimeConstant() {
        let tau = 10.0
        let s = Self.settings(band: 2, attack: tau, release: 100)
        let n = 48000
        let on = 4800
        var x = [Float](repeating: 0, count: n)
        let t = Sig.mono(3000, amplitudeDB: -10, seconds: 1)
        for i in on..<n { x[i] = t[i] }
        let y = Self.run(s, x)
        let steady = -15.0
        for (mult, tol) in [(0.5, 1.0), (1.0, 1.0), (3.0, 1.0)] {
            let at = on + Int(tau * mult * 48)
            let expected = steady * (1 - exp(-mult))
            let g = Self.gainDB(y, at: at, inputDB: -10)
            #expect(abs(g - expected) < tol, "t=\(mult)tau: \(g) vs \(expected)")
        }
    }

    @Test func releaseTimeConstant() {
        let tau = 50.0
        let s = Self.settings(band: 2, attack: 1, release: tau)
        let on = 24000
        var x = Sig.mono(3000, amplitudeDB: -10, seconds: 2)
        for i in on..<x.count { x[i] *= 0.01 }                  // drops to -50 dB, far below threshold
        let y = Self.run(s, x)
        #expect(abs(Self.gainDB(y, at: on - 2400, inputDB: -10) + 15) < 1.0)       // steady before (short release: some ripple)
        for mult in [0.5, 1.0, 2.0] {
            let at = on + Int(tau * mult * 48)
            let expected = -15 * exp(-mult)
            let g = Self.gainDB(y, at: at, inputDB: -50)
            #expect(abs(g - expected) < 1.5, "t=\(mult)tau: \(g) vs \(expected)")
        }
        #expect(abs(Self.gainDB(y, at: on + Int(tau * 8 * 48), inputDB: -50)) < 0.2)
    }

    // MARK: bypass, streaming

    @Test func bypassIsTransparent() {
        var s = Self.settings(band: 2)
        s.bypass = true
        let x = Sig.noise(amplitude: 0.5, count: 5000)
        #expect(Self.run(s, x) == x)
    }

    @Test func makeupAndPreGain() {
        var s = MultibandCompressorSettings.neutral
        s.bypass = false; s.crossoversHz = Self.xo
        s.preGainDB = -6; s.makeupGainDB = 10
        let x = Sig.mono(3000, amplitudeDB: -30, seconds: 1)
        let y = Self.run(s, x)
        #expect(abs(Sig.db(Sig.amplitude(y[24000...], freq: 3000)) - (-30 + 4)) < 0.1)
    }

    @Test func chunkingMatchesOneShot() {
        let s = TrackAudioPreset.voice.compressor
        let n = 48000
        let x = [Sig.noise(amplitude: 0.4, count: n, seed: 7), Sig.noise(amplitude: 0.4, count: n, seed: 8)]
        var one = MultibandCompressor(settings: s, sampleRate: 48000, channels: 2)
        var whole = x; one.process(&whole)
        var c = MultibandCompressor(settings: s, sampleRate: 48000, channels: 2)
        let parts = Sig.chunked(x, sizes: [1, 7, 480, 1000, 33, 4097]).map { p -> [[Float]] in var q = p; c.process(&q); return q }
        #expect(Sig.concat(parts, channels: 2) == whole)
    }

    @Test func stereoIsLinked() {
        var s = Self.settings(band: 2)
        s.bands[2].attackMs = 1
        let loud = Sig.mono(3000, amplitudeDB: -10, seconds: 1)
        let quiet = Sig.mono(3000, amplitudeDB: -40, seconds: 1)
        var c = MultibandCompressor(settings: s, sampleRate: 48000, channels: 2)
        var b = [loud, quiet]
        c.process(&b)
        let gl = Sig.db(Sig.amplitude(b[0][24000...], freq: 3000)) + 10
        let gr = Sig.db(Sig.amplitude(b[1][24000...], freq: 3000)) + 40
        #expect(abs(gl - gr) < 0.2)             // same gain on both channels
    }
}
