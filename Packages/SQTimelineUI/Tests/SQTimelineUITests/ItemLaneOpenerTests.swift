import AppKit
import Testing
@testable import SQTimelineUI

/// The opener at a Graphic's head: a 34 pt full-height strip on wide clips, the bare arrow on narrow ones.
@MainActor @Suite struct ItemLaneOpenerTests {
    @Test func wideClipGetsAFullHeightStrip() throws {
        let clip = CGRect(x: 100, y: 10, width: 300, height: 40)
        let r = try #require(ItemLanes.chevronRect(rect: clip, visible: clip, thumb: 0))
        #expect(r.width == 34 && r.height == 40 && r.minY == 10)
        #expect(ItemLanes.chevronReserve(clipWidth: 300, thumb: 0) > ItemLanes.chevronReserve(clipWidth: 60, thumb: 0))
    }

    @Test func narrowClipKeepsTheBareArrow() throws {
        let clip = CGRect(x: 100, y: 10, width: 60, height: 40)
        let r = try #require(ItemLanes.chevronRect(rect: clip, visible: clip, thumb: 0))
        #expect(r.width == ItemLanes.chevronSize && r.height == ItemLanes.chevronSize)
        #expect(ItemLanes.chevronRect(rect: CGRect(x: 0, y: 0, width: 30, height: 40), visible: clip, thumb: 0) == nil)
    }
}
