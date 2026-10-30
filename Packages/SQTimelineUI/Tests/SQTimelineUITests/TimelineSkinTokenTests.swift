import AppKit
import SQCore
import SQUIKit
import Testing
@testable import SQTimelineUI

/// The timeline reads its alpha literals from `Theme.TimelineSkin` (design B values from sq.css).
@MainActor @Suite struct TimelineSkinTokenTests {
    private func rgba(_ c: NSColor) -> [CGFloat] {
        let s = c.usingColorSpace(.sRGB) ?? c
        return [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent]
    }

    @Test func clipEdgeIsWhiteAt22Percent() {
        #expect(rgba(Theme.TimelineSkin.clipEdge) == [1, 1, 1, 0.22])
        #expect(rgba(ClipStyle.video.edge) == rgba(Theme.TimelineSkin.clipEdge))
        for l in LabelColor.allCases { #expect(rgba(ClipStyle.label(l).edge) == rgba(Theme.TimelineSkin.clipEdge)) }
    }

    @Test func inOutBandMatchesBoardIov() {
        #expect(rgba(Theme.TimelineSkin.inOutBand) == [1, 1, 1, 0.13])
        #expect(rgba(Theme.TimelineSkin.inOutBandEdge) == [1, 1, 1, 0.38])
    }

    @Test func thumbRuleAndWaveform() {
        #expect(rgba(Theme.TimelineSkin.thumbRule) == [0, 0, 0, 0.35])
        #expect(rgba(Theme.TimelineSkin.waveform) == [1, 1, 1, 0.55])
    }

    @Test func darkClipNameIsBlack() {
        #expect(rgba(Theme.TimelineSkin.nameOnLight) == [0, 0, 0, 1])
    }
}
