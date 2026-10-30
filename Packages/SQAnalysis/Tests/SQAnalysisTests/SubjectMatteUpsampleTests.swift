import Foundation
import SQCore
import Testing
@testable import SQAnalysis

/// The vDSP upsample gives what `SubjectTrackRules.matte` gives (SQCore's loop stays the reference).
@Suite struct SubjectMatteUpsampleTests {
    static func logits(_ size: Int) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        var v = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                // A blob with a soft ramp, far-out areas beyond +-9, and a little noise.
                let d = (Float(x - size / 2) * Float(x - size / 2) + Float(y - size / 2) * Float(y - size / 2)).squareRoot()
                v[y * size + x] = (Float(size) * 0.25 - d) * 0.7 + Float.random(in: -0.2...0.2, using: &rng)
            }
        }
        return v
    }

    @Test(arguments: [(1920, 1080), (1080, 1920), (256, 256), (100, 37), (300, 300)])
    func matchesTheReference(_ dims: (Int, Int)) {
        let l = Self.logits(256)
        let a = SubjectTrackRules.matte(logits: l, size: 256, width: dims.0, height: dims.1)
        let b = SubjectMatteUpsample.matte(logits: l, size: 256, width: dims.0, height: dims.1)
        #expect(a.width == b.width && a.height == b.height)
        var worst: Float = 0
        for i in 0..<a.values.count { worst = max(worst, abs(a.values[i] - b.values[i])) }
        #expect(worst < 1e-5, "worst difference \(worst)")
    }

    @Test func farOutLogitsStayExactlyBlankAndFull() {
        let out = SubjectMatteUpsample.matte(logits: [Float](repeating: -12, count: 64 * 64), size: 64, width: 200, height: 120)
        #expect(out.isBlank)
        let full = SubjectMatteUpsample.matte(logits: [Float](repeating: 12, count: 64 * 64), size: 64, width: 200, height: 120)
        #expect(full.values.allSatisfy { $0 == 1 })
    }

    @Test func isFasterThanTheReference() {
        let l = Self.logits(256)
        let clock = ContinuousClock()
        let old = clock.measure { _ = SubjectTrackRules.matte(logits: l, size: 256, width: 1920, height: 1080) }
        let new = clock.measure { _ = SubjectMatteUpsample.matte(logits: l, size: 256, width: 1920, height: 1080) }
        #expect(new < old, "UPSAMPLE 1080p: SQCore loop \(old), vDSP \(new)")
    }
}
