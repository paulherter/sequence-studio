#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import SQUIKit
@testable import SQTimelineUI

@Suite struct WaveformClippingTests {
    private func col(_ hi: Float, clipped: Bool = false) -> WaveformColumn { WaveformColumn(lo: 0, hi: hi, clipped: clipped) }

    @Test func levelsFollowThePeak() {
        #expect(WaveformClipping.level(of: col(0.5)) == .clear)
        #expect(WaveformClipping.level(of: col(0.9)) == .near)
        #expect(WaveformClipping.level(of: col(1.0)) == .over)
        #expect(WaveformClipping.level(of: col(0.5, clipped: true)) == .over)
    }

    @Test func bandsCoverOnlyTheTopOfLoudColumns() {
        let rect = CGRect(x: 0, y: 0, width: 4, height: 40)
        let cols = [[col(0.5), col(0.95), col(1.0), col(0.2)]]
        let b = WaveformClipping.bands(columns: cols, rect: rect, style: WaveformStyle())
        // Rectified: column 1 is near, column 2 is over; the band runs from the peak down to -1 dBFS.
        #expect(!b.near.isEmpty && !b.over.isEmpty)
        #expect(b.near.boundingBoxOfPath.minX == 1 && b.near.boundingBoxOfPath.maxX == 2)
        #expect(b.over.boundingBoxOfPath.minX == 2 && b.over.boundingBoxOfPath.maxX == 3)
        #expect(b.over.boundingBoxOfPath.minY == 0)
        #expect(b.over.boundingBoxOfPath.height < 40 * 0.12 + 1)
    }

    @Test func quietWaveformHasNoBands() {
        let b = WaveformClipping.bands(columns: [[col(0.3), col(0.6)]], rect: CGRect(x: 0, y: 0, width: 2, height: 30), style: WaveformStyle())
        #expect(b.near.isEmpty && b.over.isEmpty)
    }
}
