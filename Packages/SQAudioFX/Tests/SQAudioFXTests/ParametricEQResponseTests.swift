import Testing
import Foundation
@testable import SQAudioFX
import SQCore

@Suite("ParametricEQResponse")
struct ParametricEQResponseTests {
    private func values() -> AudioParametricEQValues {
        func off(_ hz: Double) -> AudioPEQBand { AudioPEQBand(on: false, hz: hz) }
        return AudioParametricEQValues(
            hp: AudioPEQBand(on: true, hz: 80, q: 0.7071), lowShelf: AudioPEQBand(on: true, hz: 120, gainDB: 4, q: 0.71),
            b1: off(100), b2: AudioPEQBand(on: true, hz: 400, gainDB: -6, q: 2), b3: AudioPEQBand(on: true, hz: 1500, gainDB: 9, q: 1),
            b4: off(4000), b5: off(10000), highShelf: AudioPEQBand(on: true, hz: 8000, gainDB: -3, q: 0.71),
            lp: AudioPEQBand(on: true, hz: 16000, q: 0.7071))
    }

    /// Run the real stage on a sine and measure the output level; it must match the drawn magnitude.
    @Test func drawnMagnitudeMatchesTheRealFilter() {
        let v = values(), fs = ParametricEQResponse.sampleRate
        for hz in [60.0, 200, 400, 1500, 3000, 9000, 15000] {
            let n = 48_000
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: n)
            defer { buf.deallocate() }
            for i in 0..<n { buf[i] = Float(sin(2 * Double.pi * hz * Double(i) / fs)) }
            let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1)
            defer { ptrs.deallocate() }
            ptrs[0] = buf
            let stage = ParametricEQStage(channels: 1)
            stage.process(ptrs, channels: 1, frames: n, from: v, to: v, sampleRate: fs)
            var peak: Float = 0
            for i in (n / 2)..<n { peak = max(peak, abs(buf[i])) }
            let measured = 20 * log10(Double(peak))
            #expect(abs(measured - ParametricEQResponse.totalDB(v, hz: hz)) < 0.15, "at \(hz) Hz")
        }
    }

    @Test func offBandsAddNothingAndBatchEqualsSingle() {
        var v = values()
        v.b2.on = false
        #expect(ParametricEQResponse.bandDB(v, filter: 3, hz: 400) == 0)
        let f = [30.0, 400, 2000, 12000]
        var out: [Double] = []
        ParametricEQResponse.totalDB(v, at: f, into: &out)
        for (i, hz) in f.enumerated() { #expect(abs(out[i] - ParametricEQResponse.totalDB(v, hz: hz)) < 1e-9) }
    }

    @Test func peakCenterReachesItsGain() {
        let v = values()
        #expect(abs(ParametricEQResponse.bandDB(v, filter: 4, hz: 1500) - 9) < 0.01)
    }
}
