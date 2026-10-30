import AppKit
import Testing
import Foundation
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQTimelineUI
@testable import SQUIKit
import SQCore

@Suite struct TooltipTimingTests {
    @Test func firstTipWaitsTheFullDelay() {
        #expect(SQTooltipLayout.showDelay(now: 100, lastExit: nil) == SQTooltipLayout.delay)
        #expect(SQTooltipLayout.delay >= 0.5 && SQTooltipLayout.delay <= 1.2)
    }

    @Test func neighborAfterAnExitShowsAtOnce() {
        #expect(SQTooltipLayout.showDelay(now: 100.2, lastExit: 100) == 0)
        #expect(SQTooltipLayout.showDelay(now: 100 + SQTooltipLayout.handOverWindow, lastExit: 100) == 0)
    }

    @Test func handOverEndsAfterTheWindow() {
        #expect(SQTooltipLayout.showDelay(now: 101, lastExit: 100) == SQTooltipLayout.delay)
    }

    @Test func aTipOnScreenHandsOverAtOnce() {
        #expect(SQTooltipLayout.showDelay(now: 100, lastExit: nil, shownNow: true) == 0)
    }

    @Test func textAndShortcutFormat() {
        #expect(Tooltip.text("Snap", shortcut: "S") == "Snap (S)")
        #expect(Tooltip.text("Snap", shortcut: nil) == "Snap")
        #expect(Tooltip.text("Snap.", shortcut: " ") == "Snap")
        let (name, key) = SQTooltipLayout.split(Tooltip.text("Mark In", shortcut: "I"))
        #expect(name == "Mark In" && key == "I")
    }

    @MainActor @Test func stabilizerIsFoundByItsNamesAndByWhatItDoes() {
        for q in ["stabilizer", "stabilize", "stabilise", "steady", "shake", "warp"] {
            #expect(EffectsPanelView.rows(matching: q).map(\.id).contains(ClipEffect.stabilizeKind), "\(q) should find the Stabilizer")
        }
    }

    @MainActor @Test func tooBroadWordsDoNotFindTheStabilizer() {
        for q in ["camera", "smooth"] {
            #expect(!EffectsPanelView.rows(matching: q).map(\.id).contains(ClipEffect.stabilizeKind), "\(q) alone must not find the Stabilizer")
        }
    }

    @MainActor @Test func tooltipAreaSurvivesUpdateTrackingAreas() {
        let b = TimelineToolSlotButton(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        b.toolTip = "Select (V)"
        func has() -> Bool { b.trackingAreas.contains { $0.owner is SQTooltipTracker } }
        #expect(has())
        b.updateTrackingAreas()
        #expect(has())
        b.trackingAreas.forEach(b.removeTrackingArea)   // a host that drops everything
        b.sqToolTip = "Select (V)"
        #expect(has())
        b.sqToolTip = "Other"
        #expect(has())
    }

    @MainActor @Test func shownTipHidesWhenItsAnchorIsHidden() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        w.contentView?.addSubview(v)
        SQTooltip.shared.show(text: "Tip", anchor: v)
        #expect(SQTooltip.shared.currentText == "Tip")
        SQTooltip.shared.validateAnchor()
        #expect(SQTooltip.shared.currentText == "Tip" || !w.isVisible)
        v.isHidden = true
        SQTooltip.shared.validateAnchor()
        #expect(SQTooltip.shared.currentText == nil)
        SQTooltip.shared.show(text: "Tip", anchor: v)
        v.isHidden = false
        v.removeFromSuperview()
        SQTooltip.shared.validateAnchor()
        #expect(SQTooltip.shared.currentText == nil)
    }

    @MainActor @Test func buttonTipsAreOwnTooltips() {
        let b = IconButton(symbol: .toolBlade, label: "Blade", command: nil) {}
        #expect(b.toolTip == "Blade")
        #expect(b.sqToolTip == "Blade")
    }
}
