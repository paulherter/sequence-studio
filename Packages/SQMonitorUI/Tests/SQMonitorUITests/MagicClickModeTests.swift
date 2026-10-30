import AppKit
import Foundation
import SQCore
import Testing
@testable import SQMonitorUI

// The Program monitor's Magic Add | Remove switch (Option flips it) and the click dots of the shown frame.

@MainActor
@Suite struct MagicClickModeTests {
    @Test func optionFlipsTheChosenMode() {
        #expect(MagicClickMode.add.effective(option: false) == .add)
        #expect(MagicClickMode.add.effective(option: true) == .remove)
        #expect(MagicClickMode.remove.effective(option: false).subtracts)
        #expect(!MagicClickMode.remove.effective(option: true).subtracts)
    }

    @Test func markersShowThePointsOfTheShownFrame() {
        let fd = Time(1, 24)
        let sel = MagicSelection(points: [
            MagicPoint(position: Vec2(0.2, 0.2), subtract: false, sourceTime: Time(11, 1)),
            // A correction stored at the decoded frame's time, a little before the playhead's source time.
            MagicPoint(position: Vec2(0.5, 0.5), subtract: true, sourceTime: Time(1_199_999, 100_000)),
        ])
        #expect(MagicMarker.markers(sel, sourceTime: Time(11, 1), frameDuration: fd) == [MagicMarker(position: Vec2(0.2, 0.2), subtract: false)])
        #expect(MagicMarker.markers(sel, sourceTime: Time(12, 1), frameDuration: fd) == [MagicMarker(position: Vec2(0.5, 0.5), subtract: true)])
        #expect(MagicMarker.markers(sel, sourceTime: Time(13, 1), frameDuration: fd).isEmpty)
        #expect(MagicMarker.markers(nil, sourceTime: Time(11, 1), frameDuration: fd).isEmpty)
    }

    @Test func theSwitchSetsTheOverlayModeAndShowsOnlyForMagic() {
        let s = ProgramSurfaceView(viewer: NSView())
        #expect(s.magicSwitch.isHidden)
        s.tool = .mask(.magic)
        #expect(!s.magicSwitch.isHidden)
        s.magicMode = .remove
        #expect(s.overlay.magicMode == .remove && s.magicSwitch.selectedSegment == 1)
        s.tool = .mask(.pen)
        #expect(s.magicSwitch.isHidden)
    }
}
