import AppKit
import Testing
@testable import SQUIKit

@MainActor @Suite struct FocusRoutingTests {
    @Test func scrubFieldClaimsArrows() {
        let f = ScrubField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        #expect(KeyClaims.claimsArrowKeys(responder: f))
    }

    @Test func plainViewsDoNotClaimArrows() {
        #expect(!KeyClaims.claimsArrowKeys(responder: NSView()))
        #expect(!KeyClaims.claimsArrowKeys(responder: nil))
    }

    @Test func tablesClaimArrows() {
        #expect(KeyClaims.claimsArrowKeys(responder: NSTableView()))
    }

    @Test func claimingMarkerIsHonoured() {
        final class V: NSView, KeyClaiming { var claimsArrowKeys = false }
        let v = V()
        #expect(!KeyClaims.claimsArrowKeys(responder: v))
        v.claimsArrowKeys = true
        #expect(KeyClaims.claimsArrowKeys(responder: v))
    }

    @Test func targetFollowsFocusedPanel() {
        #expect(FocusedEditTarget(panel: .timeline) == .timeline)
        #expect(FocusedEditTarget(panel: nil) == .timeline)
        #expect(FocusedEditTarget(panel: .programMonitor) == .timeline)
        #expect(FocusedEditTarget(panel: .effectControls) == .effectControls)
        #expect(FocusedEditTarget(panel: .project) == .project)
        #expect(FocusedEditTarget(panel: .graphics) == .graphics)
        #expect(FocusedEditTarget(panel: .keystones) == .keystones)
        #expect(FocusedEditTarget(panel: .effects) == .none)
        #expect(FocusedEditTarget(panel: .text) == .captions)
    }

    @Test func editTable() {
        for v in EditVerb.allCases { #expect(FocusedEditTarget.timeline.handles(v)) }
        // Graphics: delete and select all only, never the timeline's clipboard.
        #expect(FocusedEditTarget.graphics.handles(.delete))
        #expect(FocusedEditTarget.graphics.handles(.selectAll))
        #expect(!FocusedEditTarget.graphics.handles(.copy))
        #expect(!FocusedEditTarget.graphics.handles(.paste))
        #expect(FocusedEditTarget.project.handles(.delete))
        #expect(!FocusedEditTarget.project.handles(.cut))
        #expect(!FocusedEditTarget.project.handles(.selectAll))
        for v in EditVerb.allCases where v != .selectAll { #expect(FocusedEditTarget.effectControls.handles(v)) }
        #expect(!FocusedEditTarget.effectControls.handles(.selectAll))
        for v in EditVerb.allCases {
            #expect(!FocusedEditTarget.none.handles(v))
            // Keystones and Captions lists: Delete only (SH-43).
            #expect(FocusedEditTarget.keystones.handles(v) == (v == .delete))
            #expect(FocusedEditTarget.captions.handles(v) == (v == .delete))
        }
    }

    @Test func commandMapsToVerb() {
        #expect(EditVerb(command: .selectAll) == .selectAll)
        #expect(EditVerb(command: .copy) == .copy)
        #expect(EditVerb(command: .rippleDelete) == .delete)
        #expect(EditVerb(command: .delete) == .delete)
        #expect(EditVerb(command: .playPause) == nil)
    }
}
