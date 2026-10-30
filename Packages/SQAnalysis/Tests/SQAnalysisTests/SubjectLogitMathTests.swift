import Foundation
import SQCore
import Testing
@testable import SQAnalysis

/// The optimized logit loops give exactly what SQCore's give (`SubjectTrackRules.stats`, `SubjectCropPass.constrain`
/// stay the reference).
@Suite struct SubjectLogitMathTests {
    static func logits(_ size: Int, center: (Int, Int), radius: Float) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        var v = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let dx = Float(x - center.0), dy = Float(y - center.1)
                v[y * size + x] = (radius - (dx * dx + dy * dy).squareRoot()) * 0.7 + Float.random(in: -0.2...0.2, using: &rng)
            }
        }
        return v
    }

    @Test(arguments: [(128, 128, 40), (10, 240, 30), (250, 5, 12), (128, 128, -5)])
    func statsMatchTheReference(_ blob: (Int, Int, Int)) {
        let l = Self.logits(256, center: (blob.0, blob.1), radius: Float(blob.2))
        let a = SubjectTrackRules.stats(logits: l, size: 256)
        let b = SubjectLogitMath.stats(logits: l, size: 256)
        #expect(a.area == b.area && a.box == b.box)
    }

    @Test func statsOfAnEmptyAndAFullFrame() {
        #expect(SubjectLogitMath.stats(logits: [Float](repeating: -1, count: 64), size: 8).box == nil)
        let full = SubjectLogitMath.stats(logits: [Float](repeating: 1, count: 64), size: 8)
        #expect(full.area == 1 && full.box == SubjectTrackBox(x0: 0, y0: 0, x1: 1, y1: 1))
    }

    @Test(arguments: [SubjectTrackBox(x0: 0.2, y0: 0.3, x1: 0.6, y1: 0.9), SubjectTrackBox(x0: -0.2, y0: -0.1, x1: 0.4, y1: 0.5),
                      SubjectTrackBox(x0: 0, y0: 0, x1: 1, y1: 1), SubjectTrackBox(x0: 0.5, y0: 0.5, x1: 0.5, y1: 0.5),
                      SubjectTrackBox(x0: 0.7, y0: 0.1, x1: 1.3, y1: 0.2)])
    func constrainMatchesTheReference(_ band: SubjectTrackBox) {
        let l = Self.logits(256, center: (128, 128), radius: 60)
        #expect(SubjectLogitMath.constrain(l, size: 256, to: band) == SubjectCropPass.constrain(l, size: 256, to: band))
    }

    @Test func isFasterThanTheReference() {
        let l = Self.logits(256, center: (128, 128), radius: 60)
        let band = SubjectTrackBox(x0: 0.2, y0: 0.3, x1: 0.6, y1: 0.9)
        let clock = ContinuousClock()
        let old = clock.measure { _ = SubjectTrackRules.stats(logits: SubjectCropPass.constrain(l, size: 256, to: band), size: 256) }
        let new = clock.measure { _ = SubjectLogitMath.stats(logits: SubjectLogitMath.constrain(l, size: 256, to: band), size: 256) }
        #expect(new <= old, "LOGITS 256: SQCore \(old), optimized \(new)")
    }
}
