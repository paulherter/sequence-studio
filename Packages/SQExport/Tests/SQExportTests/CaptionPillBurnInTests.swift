import Foundation
import Testing
import SQCore
import SQText
import SQTranscribe
@testable import SQExport

@Suite struct CaptionPillBurnInTests {
    /// Burn-in lays the caption out with `CaptionLayout` at its placement's width; the pill look needs the placement to
    /// match the monitor's (`CaptionLayout.widthFraction`), and the short-video preset must resolve to the pill style.
    @Test func burnInPlacementMatchesTheMonitorAndShortVideoUsesThePill() {
        #expect(CaptionPlacement.bottomSafeArea.maxWidthFraction == CaptionLayout.widthFraction)
        #expect(CaptionPlacement.bottomSafeArea.bottomMargin == CaptionLayout.bottomMargin)
        let lib = CaptionPresetLibrary.builtIn
        #expect(lib.hasStyle(CaptionPreset.shortVideo.styleRef))
        #expect(lib.style(for: CaptionPreset.shortVideo.styleRef).background != nil)
    }

    /// FB-Y: the burn-in takes the caption position of the project's kit from its library.
    @Test func burnInTakesTheKitPosition() {
        let p = CaptionPosition(vertical: .middle, horizontal: .right, offsetY: -0.1)
        let lib = CaptionLookRegistry.shared.library(for: StyleKit(captionPosition: p))
        #expect(CaptionBurnIn(captions: [], library: lib).position == p)
    }

    @Test func burnInStateForAPillCaption() throws {
        let c = Caption(lines: ["Wow"], range: TimeRange(start: .zero, end: Time(1, 1)), styleRef: CaptionPill.styleID, animationRef: "")
        let burn = CaptionBurnIn(captions: [c], library: .builtIn)
        let s = try #require(burn.state(at: Time(1, 2), canvasWidth: 540, canvasHeight: 960))
        #expect(s.index == 0)
    }
}
