import Testing
import SQDrawKit
import SQUIKit
@testable import SQDrawTimeline

/// TimelineSkin reads `SQTokens`; the Mac `Theme.TimelineSkin` reads the same ones, so the two cannot drift.
@MainActor @Suite struct TimelineSkinTokensTests {
    @Test func skinPaintsAreTheTokens() {
        let s = TimelineSkin(theme: DrawTheme())
        #expect(abs(Double(s.clipEdge.a) - SQTokens.Alpha.clipEdge) < 1e-6)
        #expect(abs(Double(s.thumbRule.a) - SQTokens.Alpha.thumbRule) < 1e-6)
        #expect(abs(Double(s.inOutBand.a) - SQTokens.Alpha.inOutBand) < 1e-6)
        #expect(abs(Double(s.inOutBandEdge.a) - SQTokens.Alpha.inOutBandEdge) < 1e-6)
        #expect(abs(Double(s.clipShade.a) - SQTokens.Alpha.clipShade) < 1e-6)
        #expect(abs(Double(s.cacheStrip.a) - SQTokens.Alpha.cacheStrip) < 1e-6)
        #expect(abs(Double(s.badgeFill.a) - SQTokens.Alpha.badgeFill) < 1e-6)
        #expect(abs(Double(s.badgeEdge.a) - SQTokens.Alpha.badgeEdge) < 1e-6)
        #expect(s.snapLine == DrawColor(hex: SQTokens.Hex.yellow))
        #expect(s.thumbWell == DrawColor(hex: SQTokens.Hex.thumbWell))
        #expect(s.offlineClip == DrawTheme().overlay)       // artifact --clip-off
        #expect(Double(TimelineSkin.selectionOutlineWidth) == SQTokens.Timeline.selectionOutlineWidth)
        #expect(Double(TimelineSkin.headSize.width) == SQTokens.Timeline.headSize)
    }

}

