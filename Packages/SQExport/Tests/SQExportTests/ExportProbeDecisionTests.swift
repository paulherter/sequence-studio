import Testing
@testable import SQExport

@Suite struct ExportProbeDecisionTests {
    @Test func renderBoundHeadRunsPlannedSegments() {
        #expect(ExportWriter.restSegments(waitShare: 0.9, planned: 2) == 2)
        #expect(ExportWriter.restSegments(waitShare: 0.41, planned: 2) == 2)
    }
    @Test func encoderBoundHeadRunsOneSegment() {
        // Measured shares of encoder-bound exports: plain 0.02-0.03, fx + caption 0.19-0.30.
        for share in [0.0, 0.02, 0.30, 0.4] { #expect(ExportWriter.restSegments(waitShare: share, planned: 2) == 1) }
    }
    @Test func missingReadingCountsAsRenderBound() {
        #expect(ExportWriter.restSegments(waitShare: nil, planned: 2) == 2)
        #expect(ExportWriter.restSegments(waitShare: nil, planned: 0) == 1)
    }
}
