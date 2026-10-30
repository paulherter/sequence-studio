import Testing
import Foundation
@testable import SQAudioFX

@Suite struct MasterLimiterInterleavedTests {
    private func signal(frames: Int, channels: Int) -> [Float] {
        var s = [Float](repeating: 0, count: frames * channels)
        for i in 0..<frames {
            let burst: Float = (i % 4800) < 48 ? 1.6 : 0.3
            for c in 0..<channels { s[i * channels + c] = burst * Float(sin(Double(i) * 0.13 + Double(c))) }
        }
        return s
    }

    @Test func stereoMatchesPlanarProcess() {
        let n = 9600
        let inter = signal(frames: n, channels: 2)
        var l = (0..<n).map { inter[$0 * 2] }, r = (0..<n).map { inter[$0 * 2 + 1] }
        var a = MasterLimiter(sampleRate: 48_000, ceilingDB: -3)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            a.process(left: lp.baseAddress!, right: rp.baseAddress!, count: n) } }
        var b = MasterLimiter(sampleRate: 48_000, ceilingDB: -3)
        var x = inter
        x.withUnsafeMutableBufferPointer { b.process(interleaved: $0.baseAddress!, channels: 2, count: n) }
        for i in 0..<n { #expect(x[i * 2] == l[i] && x[i * 2 + 1] == r[i]) }
    }

    @Test(arguments: [1, 3, 6]) func ceilingHoldsForAnyChannelCount(channels: Int) {
        let n = 9600
        var x = signal(frames: n, channels: channels)
        var lim = MasterLimiter(sampleRate: 48_000, ceilingDB: -6)
        x.withUnsafeMutableBufferPointer { lim.process(interleaved: $0.baseAddress!, channels: channels, count: n) }
        #expect((x.map { abs($0) }.max() ?? 0) <= Float(lim.ceiling))
    }
}
