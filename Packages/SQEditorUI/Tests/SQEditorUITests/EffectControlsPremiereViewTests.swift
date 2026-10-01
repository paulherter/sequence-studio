import AppKit
import Foundation
import Testing
import SQCore
@testable import SQEditorUI

@MainActor @Suite struct EffectControlsPremiereViewTests {
    // MARK: Effects panel
    @Test func effectsPanelListsOnlyWhatExistsUnderItsBin() {
        let rows = EffectsPanelView.rows(matching: "")
        #expect(rows.map(\.title) == ["Video Effects", "Rounded Corners"])
        #expect(rows[0].isHeader && !rows[1].isHeader)
    }

    @Test func effectsSearchFiltersAndDropsEmptyBins() {
        #expect(EffectsPanelView.rows(matching: "round").map(\.title) == ["Video Effects", "Rounded Corners"])
        #expect(EffectsPanelView.rows(matching: "ROUND").count == 2)
        #expect(EffectsPanelView.rows(matching: "dissolve").isEmpty)
        #expect(EffectsPanelView.rows(matching: "video").count == 2)       // matches the bin name
    }

    // MARK: Tab order
    @Test func tabOrderGoesLeftToRightTopToBottom() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        func field(_ x: CGFloat, _ y: CGFloat) -> ScrubField {
            let f = ScrubField(frame: NSRect(x: x, y: y, width: 60, height: 20)); root.addSubview(f); return f
        }
        // not flipped root: larger y is higher on screen
        let a = field(10, 150), b = field(80, 150), c = field(10, 100)
        let all = [c, b, a]
        #expect(ScrubField.neighbour(of: a, in: all, forward: true) === b)
        #expect(ScrubField.neighbour(of: b, in: all, forward: true) === c)
        #expect(ScrubField.neighbour(of: c, in: all, forward: true) === a)          // wraps
        #expect(ScrubField.neighbour(of: a, in: all, forward: false) === c)
    }

    // MARK: Key menu
    func lanes(selectKey: Bool) -> EffectKeyframeLanesView {
        let m = EffectControlsModel()
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        c.animation.opacity.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: 0.0), Keyframe(time: Time(2, 1), value: 1.0)])
        m.onEdit = { n, _, _ in m.setClip(n) }
        m.setClip(c)
        if selectKey { m.selectKey(.opacity, id: c.animation.opacity.track.keys[0].id, extend: false) }
        return EffectKeyframeLanesView(model: m)
    }

    @Test func keyMenuHasPremiereInterpolationEntries() {
        let menu = lanes(selectKey: true).makeKeyMenu(onKey: true)!
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["Linear", "Bezier", "Ease In", "Ease Out", "Easy Ease", "Hold", "Saved Curves", "Copy", "Delete"])
    }

    @Test func emptySpaceMenuHasNoDeadEntries() {
        #expect(lanes(selectKey: false).makeKeyMenu(onKey: false) == nil)
    }
}
