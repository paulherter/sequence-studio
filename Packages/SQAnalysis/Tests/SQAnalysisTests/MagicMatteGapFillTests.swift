import Foundation
import Testing
import SQCore
@testable import SQAnalysis

/// A hole of 1-2 tracked frames is drawn with the neighbor's matte moved onto the interpolated centroid, so it does not
/// sit behind in one half of the hole and ahead in the other.
struct MagicMatteGapFillTests {
    private let w = 854, h = 480, fps = 30.0

    /// A 60 x 80 px blob whose left edge is at `x` (px, may be fractional is not needed: integer here).
    private func blob(x: Int) -> SubjectMatte {
        var v = [Float](repeating: 0, count: w * h)
        for yy in 200 ..< 280 { for xx in x ..< x + 60 { v[yy * w + xx] = 1 } }
        return SubjectMatte(width: w, height: h, values: v)
    }

    private func store(missing: Set<Int>) -> MagicMatteStore {
        let s = MagicMatteStore(directory: nil)
        for i in 0 ..< 10 where !missing.contains(i) { s.put(blob(x: 100 + 7 * i), key: "k", pts: Double(i) / fps) }
        return s
    }

    @Test(arguments: [[4], [4, 5], [3, 4]])
    func gapFramesLandOnTheInterpolatedCentroid(missing: [Int]) throws {
        let s = store(missing: Set(missing))
        for i in missing {
            let m = try #require(s.matte(key: "k", pts: Double(i) / fps, feather: 0, expansion: 0, frameWidth: Double(w), fills: true))
            let c = try #require(m.centroid)
            let want = Double(100 + 7 * i) + 30       // blob center x
            #expect(abs(c.x - want) < 1, "frame \(i): \(c.x) vs \(want)")
            #expect(abs(c.y - 240) < 1)
        }
    }

    @Test func playbackReadsTheSameShiftedMatte() throws {
        let s = store(missing: [4, 5])
        let m = try #require(s.preparedMatte(key: "k", pts: 5.0 / fps, feather: 0, expansion: 0, frameWidth: Double(w)))
        #expect(abs((m.centroid?.x ?? 0) - Double(100 + 35 + 30)) < 1)
    }
}
