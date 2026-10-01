import Testing
import Foundation
@testable import SSPlayback

/// Source that is 1.0 inside `[lo, hi)` and 100 (loud, easy to spot) everywhere else, `total` frames long.
private func reader(lo: Int64, hi: Int64, total: Int64 = 4_000_000) -> AudioRetimer.Read {
    { from, count, dst in
        let n = max(0, min(count, Int(total - from)))
        for i in 0..<n { let p = from + Int64(i); dst[i] = (p >= lo && p < hi) ? 1 : 100 }
        return n
    }
}

@Suite struct AudioRetimerRangeTests {
    /// Renders the whole clip (`outputFrames`) in blocks of 1024 and returns it.
    private func renderAll(speed: Double, reversed: Bool, keepsPitch: Bool, lo: Int64, hi: Int64) throws -> [Float] {
        let outFrames = Int((Double(hi - lo) / speed).rounded(.down))
        let origin = reversed ? Double(hi) : Double(lo)
        let r = AudioRetimer(maxFrames: 1024)
        var out = [Float](repeating: 0, count: outFrames)
        var o = 0
        while o < outFrames {
            let n = min(1024, outFrames - o)
            try out.withUnsafeMutableBufferPointer { p in
                try r.render(read: reader(lo: lo, hi: hi), origin: origin, speed: speed, reversed: reversed, keepsPitch: keepsPitch,
                             srcStart: lo, srcEnd: hi, firstOutput: Int64(o), count: n, into: p.baseAddress! + o)
            }
            o += n
        }
        return out
    }

    @Test func neverReadsOutsideTheRangeAndEdgesAreInside() throws {
        let lo: Int64 = 300_000
        for (speed, hi) in [(4.0, lo + 400_000), (0.25, lo + 20_000), (100.0, lo + 3_000_000)] as [(Double, Int64)] {
            for reversed in [false, true] {
                let out = try renderAll(speed: speed, reversed: reversed, keepsPitch: true, lo: lo, hi: hi)
                #expect(out.count > 3000)
                #expect(out.allSatisfy { $0 <= 1.0001 }, "speed \(speed) reversed \(reversed): leak \(out.max() ?? 0)")
                #expect(abs(out[0] - 1) < 1e-4 && abs(out[out.count - 1] - 1) < 1e-4, "speed \(speed) reversed \(reversed): edges \(out[0]) \(out[out.count - 1])")
                // No dip to silence in the body or at the end.
                #expect(out.dropFirst(10).allSatisfy { $0 > 0.99 }, "speed \(speed) reversed \(reversed): min \(out.dropFirst(10).min() ?? 0)")
            }
        }
    }

    @Test func resamplePathStaysInsideTheRangeToo() throws {
        let lo: Int64 = 1000, hi: Int64 = 1000 + 40_000
        for (speed, reversed) in [(4.0, false), (4.0, true), (0.25, false), (0.25, true), (100.0, false)] as [(Double, Bool)] {
            let out = try renderAll(speed: speed, reversed: reversed, keepsPitch: false, lo: lo, hi: hi)
            #expect(out.allSatisfy { $0 <= 1.0001 }, "speed \(speed) reversed \(reversed)")
            #expect(abs(out[0] - 1) < 1e-4)
        }
    }

    @Test func rangeShorterThanAGrainIsZeroPaddedNotLeaked() throws {
        let out = try renderAll(speed: 2, reversed: false, keepsPitch: true, lo: 5000, hi: 5000 + 1500)
        #expect(out.allSatisfy { $0 <= 1.0001 })
    }
}
