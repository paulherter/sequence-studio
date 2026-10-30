import Foundation
import SQPlayback
import Testing

@Suite("ShuttleStretch")
struct ShuttleStretchTests {
    /// Renders `frames` output frames at `rate` from a 440 Hz sine (left) and DC 0.5 (right); returns output and input used.
    private func run(rate: Double, frames: Int) -> (left: [Float], right: [Float], consumed: Int) {
        let s = ShuttleStretch()
        var l = [Float](repeating: 0, count: frames), r = [Float](repeating: 0, count: frames)
        var t = 0
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                var done = 0
                while done < frames {   // device-sized blocks, like WASAPI
                    let n = min(480, frames - done)
                    s.render(rate: rate, left: lp.baseAddress! + done, right: rp.baseAddress! + done, count: n) { a, b, c in
                        for i in 0..<c {
                            a[i] = Float(sin(2 * Double.pi * 440 * Double(t + i) / 48_000)); b[i] = 0.5
                        }
                        t += c
                    }
                    done += n
                }
            }
        }
        return (l, r, t)
    }

    private func crossings(_ x: ArraySlice<Float>) -> Int {
        zip(x.dropFirst(), x).filter { ($0.0 >= 0) != ($0.1 >= 0) }.count
    }

    @Test(arguments: [2.0, 4.0, 8.0, 0.5])
    func consumesRateTimesInputAndKeepsPitch(rate: Double) {
        let frames = 48_000
        let (l, r, used) = run(rate: rate, frames: frames)
        // Input runs `rate` times faster (give or take one grain step and one grain of look-ahead).
        let expected = rate * Double(frames)
        #expect(abs(Double(used) - expected) <= (rate + 2) * Double(ShuttleStretch.hop) + 2)
        // 440 Hz stays 440 Hz: about 880 zero crossings per second of output after the first grain.
        let c = crossings(l[(2 * ShuttleStretch.hop)...])
        let seconds = Double(frames - 2 * ShuttleStretch.hop) / 48_000
        #expect(abs(Double(c) / seconds - 880) < 880 * 0.08)
        // Overlapping grain windows sum to 1: DC passes unchanged after the first grain's rise.
        #expect(r[(ShuttleStretch.hop)...].allSatisfy { abs($0 - 0.5) < 1e-4 })
    }

    @Test func resetDropsBufferedAudio() {
        let s = ShuttleStretch()
        var l = [Float](repeating: 0, count: 64), r = l
        s.render(rate: 2, left: &l, right: &r, count: 64) { a, b, c in for i in 0..<c { a[i] = 1; b[i] = 1 } }
        s.reset()
        s.render(rate: 2, left: &l, right: &r, count: 64) { a, b, c in for i in 0..<c { a[i] = 0; b[i] = 0 } }
        #expect(l.allSatisfy { $0 == 0 } && r.allSatisfy { $0 == 0 })
    }
}
