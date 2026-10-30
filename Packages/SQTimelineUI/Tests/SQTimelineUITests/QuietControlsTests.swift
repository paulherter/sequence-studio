import AppKit
import Testing
@testable import SQTimelineUI
@testable import SQUIKit

/// V1 Quiet custom controls (docs/DESIGN-SPEC.md §2): sizes and that they keep NSButton / NSPopUpButton behavior.
@MainActor
struct QuietControlsTests {
    final class Sink: NSObject {
        var hits = 0
        @objc func fire(_ sender: Any?) { hits += 1 }
    }

    @Test func buttonBoxIsCapsuleWithElevenPadding() {
        let b = SQButton(title: "Reset", target: nil, action: nil)
        #expect(b.intrinsicContentSize.height == 22)
        let text = ("Reset" as NSString).size(withAttributes: [.font: Theme.Typography.body]).width
        #expect(abs(b.intrinsicContentSize.width - ceil(text + 22)) < 1)
        b.bezelStyle = .rounded       // old call sites must not bring the system bezel back
        #expect(b.bezelStyle == .smallSquare && !b.isBordered)
    }

    @Test func buttonSendsItsAction() {
        let s = Sink()
        let b = SQButton(title: "Go", target: s, action: #selector(Sink.fire(_:)))
        b.performClick(nil)
        #expect(s.hits == 1)
    }

    @Test func popupKeepsItsMenuAndSelection() {
        let p = SQPopup(frame: .zero, pullsDown: false)
        p.addItems(withTitles: ["Fit", "50%", "100%"])
        p.selectItem(at: 2)
        #expect(p.titleOfSelectedItem == "100%" && p.displayTitle == "100%")
        #expect(p.intrinsicContentSize.height == 22)
        let pull = SQPopup(frame: .zero, pullsDown: true)
        pull.addItems(withTitles: ["Editing", "Color"])
        #expect(pull.displayTitle == "Editing")
    }

    @Test func checkboxTogglesState() {
        let s = Sink()
        let c = SQCheckbox(target: s, action: #selector(Sink.fire(_:)))
        #expect(c.state == .off && c.intrinsicContentSize == NSSize(width: 14, height: 14))
        c.performClick(nil)
        #expect(c.state == .on && s.hits == 1)
    }

    @Test func segmentedSelectsAndSendsOnlyOnChange() {
        let s = Sink()
        let seg = SQSegmented(labels: ["Edit", "Color"], target: s, action: #selector(Sink.fire(_:)))
        seg.frame = NSRect(origin: .zero, size: seg.intrinsicContentSize)
        #expect(seg.intrinsicContentSize == NSSize(width: 122, height: 22))
        #expect(seg.segment(at: NSPoint(x: 90, y: 11)) == 1)
        #expect(seg.segment(at: NSPoint(x: 10, y: 11)) == 0)
        seg.selectedSegment = 1
        #expect(seg.selectedSegment == 1 && s.hits == 0)   // programmatic change sends nothing
    }

    @Test func searchFieldIsQuietAndTwentyTwoHigh() {
        let f = SQSearchField(frame: NSRect(x: 0, y: 0, width: 160, height: 22))
        #expect(f.cell is SQSearchFieldCell)
        #expect(f.intrinsicContentSize.height == 22)
        f.placeholderString = "Search"
        #expect(f.placeholderString == "Search")
    }

    @Test func animateRingCallsToggleAndReportsState() {
        var hits = 0
        let r = KeyframeToggleView(label: "Animate Opacity") { hits += 1 }
        #expect(r.intrinsicContentSize == NSSize(width: 14, height: 14))
        #expect(r.accessibilityPerformPress())
        #expect(hits == 1)
        r.keyState = .onKey
        #expect(r.accessibilityValue() as? Int == 1)
    }

    @Test func themeSymbolsRender() {
        #expect(Theme.symbol(.download) != nil)
    }
}

/// V1 Quiet clip badge (DESIGN-SPEC §2 / §5 item 4): a 5 pt dot, 4 pt in from the clip's top right, no "fx" text.
struct QuietFXBadgeTests {
    @Test func dotSitsFourPointsInsideTheTopRight() throws {
        let clip = CGRect(x: 100, y: 20, width: 200, height: 32)
        let r = try #require(FXBadge.frame(clipRect: clip, visible: CGRect(x: 0, y: 0, width: 1000, height: 200)))
        #expect(r.size == CGSize(width: 5, height: 5))
        #expect(r.maxX == clip.maxX - 4 && r.minY == clip.minY + 4)
    }

    @Test func dotFollowsTheVisibleEdgeAndSkipsTinyClips() throws {
        let clip = CGRect(x: 100, y: 0, width: 400, height: 32)
        let r = try #require(FXBadge.frame(clipRect: clip, visible: CGRect(x: 0, y: 0, width: 300, height: 100)))
        #expect(r.maxX == 296)
        #expect(FXBadge.frame(clipRect: CGRect(x: 0, y: 0, width: 10, height: 20), visible: .infinite) == nil)
    }
}
