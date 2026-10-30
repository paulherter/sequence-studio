import AppKit
import Testing
@testable import SQUIKit

/// Simple | Pro switch, variant B: icon (14 px) 6 px left of the label, 76 pt segments, keyboard access.
@MainActor @Suite struct SegmentedIconsTests {
    private func makeSwitch() -> SQSegmented {
        let s = SQSegmented(labels: ["Simple", "Pro"], segmentWidth: 76)
        s.images = [SQIcon.toolMask.image(size: 14), SQIcon.slidersHorizontal.image(size: 14)]
        s.showsIconBesideLabel = true
        s.acceptsKeyboard = true
        return s
    }

    @Test func segmentsKeepTheFixedWidth() {
        let s = makeSwitch()
        #expect(s.width(of: 0) == 76 && s.width(of: 1) == 76)
        #expect(abs(s.intrinsicContentSize.width - 154) < 0.01)
        #expect(s.images.allSatisfy { $0?.size == NSSize(width: 14, height: 14) })
    }

    @Test func fittedWidthAddsIconAndGap() {
        let s = makeSwitch()
        s.segmentWidth = 0
        let plain = SQSegmented(labels: ["Pro"], segmentWidth: 0)
        #expect(s.width(of: 1) - plain.width(of: 0) > 14)
    }

    @Test func arrowKeysStepAndStopAtTheEnds() {
        let s = makeSwitch()
        #expect(s.acceptsFirstResponder)
        s.step(1)
        #expect(s.selectedSegment == 1)
        s.step(1)
        #expect(s.selectedSegment == 1)
        s.step(-1)
        #expect(s.selectedSegment == 0)
    }

    @Test func keyboardIsOptIn() {
        #expect(!SQSegmented(labels: ["A", "B"]).acceptsFirstResponder)
    }
}
