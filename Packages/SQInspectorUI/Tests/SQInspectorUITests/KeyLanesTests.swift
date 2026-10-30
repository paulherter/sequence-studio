import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor @Suite struct KeyLanesTests {
    private func keyed() -> Clip {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(0), duration: s(10)), start: s(4))
        c.animation.opacity = AnimatedProperty(1.0, track: KeyframeTrack(keys: [
            Keyframe(time: s(1), value: 0.2), Keyframe(time: s(3), value: 0.9)]))
        return c
    }

    @Test func keyTimesAreTimelineTimesOfTheSelectedSectionOnly() {
        let c = keyed()
        #expect(KeyLanes.keyTimes(clip: c, section: .opacity) == [s(5), s(7)])
        #expect(KeyLanes.keyTimes(clip: c, section: .motion) == [s(5), s(7)])   // Opacity sits inside Motion
        #expect(KeyLanes.keyTimes(clip: c, section: .effect(UUID(), kind: ClipEffect.cropKind)).isEmpty)
    }

    @Test func visibleOnlyWhenSelectedTallEnoughAndKeyed() {
        let c = keyed()
        let on = KeyLanes.isVisible(clip: c, section: .opacity, selected: true, rowHeight: 60)
        let unselected = KeyLanes.isVisible(clip: c, section: .opacity, selected: false, rowHeight: 60)
        let thin = KeyLanes.isVisible(clip: c, section: .opacity, selected: true, rowHeight: 20)
        let noKeys = KeyLanes.isVisible(clip: c, section: .effect(UUID(), kind: ClipEffect.cropKind), selected: true, rowHeight: 60)
        let wrongKind = KeyLanes.isVisible(clip: c, section: .volume, selected: true, rowHeight: 60)
        let noSection = KeyLanes.isVisible(clip: c, section: nil, selected: true, rowHeight: 60)
        #expect(on == true)
        #expect(unselected == false)
        #expect(thin == false)
        #expect(noKeys == false)
        #expect(wrongKind == false)
        #expect(noSection == false)
    }

    @Test func glyphsSitOnTheLaneAtTheKeyX() {
        let c = keyed()
        let g = TimelineGeometry(frameDuration: Time(1, 30), pointsPerSecond: 100)
        let rect = CGRect(x: g.x(for: c.timeline.start), y: 0, width: g.width(of: c.duration), height: 60)
        let pts = KeyLanes.glyphCenters(clip: c, section: .opacity, clipRect: rect,
                                        visible: CGRect(x: -1000, y: 0, width: 5000, height: 60), geometry: g)
        #expect(pts.count == 2)
        #expect(abs(pts[0].x - g.x(for: s(5))) < 0.001)
        #expect(pts.allSatisfy { KeyLanes.lane(in: rect).contains($0) })
        let none = KeyLanes.glyphCenters(clip: c, section: .opacity, clipRect: rect,
                                         visible: CGRect(x: 100000, y: 0, width: 10, height: 60), geometry: g)
        #expect(none.isEmpty)
    }

    /// The portable layout the shared-toolkit timeline draws: strip, glyphs with times, picked keys, nil when hidden.
    @Test func layoutCarriesTimesAndPickedKeysAndHidesWhenNotApplicable() throws {
        let c = keyed()
        let x: (Time) -> CGFloat = { CGFloat($0.value) / CGFloat($0.timescale) * 100 }
        let rect = CGRect(x: x(c.timeline.start), y: 0, width: 1000, height: 60)
        let wide = CGRect(x: -1000, y: 0, width: 5000, height: 60)
        let k = try #require(KeyLanes.layout(clip: c, section: .opacity, clipRect: rect, visible: wide, selected: true,
                                             picked: [s(7)], frameDuration: Time(1, 30), x: x))
        #expect(k.lane == KeyLanes.lane(in: rect))
        #expect(k.glyphs.map(\.time) == [s(5), s(7)])
        #expect(k.glyphs.map(\.selected) == [false, true])
        #expect(abs(k.glyphs[0].center.x - 500) < 0.001)
        #expect(KeyLanes.layout(clip: c, section: .opacity, clipRect: rect, visible: wide, selected: false,
                                picked: [], frameDuration: Time(1, 30), x: x) == nil)
        #expect(KeyLanes.layout(clip: c, section: .opacity, clipRect: rect, visible: wide, selected: true, rowHeight: 20,
                                picked: [], frameDuration: Time(1, 30), x: x) == nil)
        #expect(KeyLanes.layout(clip: c, section: nil, clipRect: rect, visible: wide, selected: true,
                                picked: [], frameDuration: Time(1, 30), x: x) == nil)
        #expect(KeyLanes.hitTest(clip: c, section: .opacity, clipRect: rect, at: CGPoint(x: 701, y: k.lane.midY),
                                 frameDuration: Time(1, 30), x: x) == s(7))
    }
}
