import Testing
import SQCore
@testable import SQAnalysis

@Suite struct SceneCutDetectorTests {
    private func series(count: Int, noise: Double, spikes: [Int: Double]) -> [Double] {
        (0..<count).map { i in spikes[i] ?? (i == 0 ? 0 : noise * (i % 2 == 0 ? 1 : 0.5)) }
    }

    @Test func findsSpikesOverQuietFootage() {
        let d = series(count: 200, noise: 0.01, spikes: [50: 0.8, 120: 0.6])
        #expect(SceneCutDetector.cutIndices(differences: d) == [50, 120])
    }

    @Test func busyFootageNeedsABiggerJump() {
        // Constant heavy motion (0.15 per frame) never reads as a cut; a real cut on top of it does.
        let calm = series(count: 100, noise: 0.15, spikes: [:])
        #expect(SceneCutDetector.cutIndices(differences: calm).isEmpty)
        let cut = series(count: 100, noise: 0.15, spikes: [60: 0.9])
        #expect(SceneCutDetector.cutIndices(differences: cut) == [60])
    }

    @Test func weakChangeBelowFloorIsIgnored() {
        #expect(SceneCutDetector.cutIndices(differences: series(count: 100, noise: 0.01, spikes: [40: 0.1])).isEmpty)
    }

    @Test func closeSpikesKeepTheStrongerOne() {
        let d = series(count: 100, noise: 0.01, spikes: [40: 0.5, 43: 0.9])
        #expect(SceneCutDetector.cutIndices(differences: d) == [43])
    }

    @Test func tinyInputsAreSafe() {
        #expect(SceneCutDetector.cutIndices(differences: []).isEmpty)
        #expect(SceneCutDetector.cutIndices(differences: [0, 0.9]).isEmpty)
    }

    @Test func histogramDifference() {
        #expect(SceneCutDetector.histogramDifference([4, 0], [4, 0]) == 0)
        #expect(SceneCutDetector.histogramDifference([4, 0], [0, 8]) == 1)
        #expect(SceneCutDetector.histogramDifference([1, 1], [3, 3]) == 0)
    }
}
