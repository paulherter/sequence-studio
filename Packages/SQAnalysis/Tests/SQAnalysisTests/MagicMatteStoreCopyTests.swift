import Foundation
import SQCore
import Testing
@testable import SQAnalysis

// A corrected Magic pick keeps the tracked frames its correction does not change: they are copied to the new key.

@Suite struct MagicMatteStoreCopyTests {
    @Test func copiesOnlyTheFramesBeforeTheCorrection() {
        let store = MagicMatteStore(directory: nil)
        let m = SubjectMatte(width: 4, height: 2, values: [Float](repeating: 1, count: 8))
        for i in 0..<6 { store.put(m, key: "old", pts: Double(i) / 24) }
        store.put(m, key: "new", pts: 3.0 / 24)
        let n = store.copyFrames(from: "old", to: "new", where: { $0 < 3.0 / 24 - 1e-6 })
        #expect(n == 3)
        #expect(store.times(key: "new").count == 4)
        #expect(store.times(key: "new") == store.times(key: "new").sorted())
        #expect(store.matte(key: "new", pts: 1.0 / 24) != nil)
        #expect(store.times(key: "old").count == 6)
    }
}
