import Testing
import CoreGraphics
@testable import SQUIKit

@Suite struct SQPopoverLogicTests {
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 200, height: 100)

    @Test func belowWhenRoom() {
        let anchor = CGRect(x: 400, y: 400, width: 40, height: 20)
        let r = SQPopoverLogic.frame(size: size, anchor: anchor, side: .below, visible: visible)
        #expect(r.side == .below)
        #expect(r.frame.maxY == anchor.minY - 4)
        #expect(r.frame.midX == anchor.midX)
    }
    @Test func flipsWhenNoRoom() {
        let anchor = CGRect(x: 400, y: 20, width: 40, height: 20)
        let r = SQPopoverLogic.frame(size: size, anchor: anchor, side: .below, visible: visible)
        #expect(r.side == .above)
        #expect(r.frame.minY == anchor.maxY + 4)
    }
    @Test func clampsToScreenEdge() {
        let r = SQPopoverLogic.frame(size: size, anchor: CGRect(x: 990, y: 400, width: 10, height: 20), side: .below, visible: visible)
        #expect(r.frame.maxX <= visible.maxX - 6)
        let l = SQPopoverLogic.frame(size: size, anchor: CGRect(x: 0, y: 400, width: 10, height: 20), side: .above, visible: visible)
        #expect(l.frame.minX >= 6)
    }
    @Test func sideFlipsHorizontally() {
        let r = SQPopoverLogic.frame(size: size, anchor: CGRect(x: 950, y: 400, width: 20, height: 20), side: .right, visible: visible)
        #expect(r.side == .left)
    }
    @Test func dismissRules() {
        typealias L = SQPopoverLogic
        #expect(L.shouldDismiss(.transient, .clickOutsideInApp))
        #expect(L.shouldDismiss(.transient, .clickOutsideOtherApp))
        #expect(L.shouldDismiss(.transient, .appDeactivated))
        #expect(!L.shouldDismiss(.transient, .clickInside))
        #expect(L.shouldDismiss(.semiTransient, .clickOutsideInApp))
        #expect(!L.shouldDismiss(.semiTransient, .clickOutsideOtherApp))
        #expect(!L.shouldDismiss(.semiTransient, .appDeactivated))
        #expect(!L.shouldDismiss(.applicationDefined, .clickOutsideInApp))
        #expect(L.shouldDismiss(.applicationDefined, .escape))
    }
}

@Suite struct SQPopoverDismissTests {
    @Test func outsideClickDismissesTransientAndSemi() {
        #expect(SQPopoverLogic.shouldDismiss(.transient, .clickOutsideInApp))
        #expect(SQPopoverLogic.shouldDismiss(.semiTransient, .clickOutsideInApp))
        #expect(!SQPopoverLogic.shouldDismiss(.applicationDefined, .clickOutsideInApp))
        #expect(!SQPopoverLogic.shouldDismiss(.transient, .clickInside))
        #expect(SQPopoverLogic.shouldDismiss(.transient, .clickOutsideOtherApp))
        #expect(SQPopoverLogic.shouldDismiss(.transient, .appDeactivated))
    }
}
