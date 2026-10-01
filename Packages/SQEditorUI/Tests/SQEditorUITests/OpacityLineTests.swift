import AppKit
import Foundation
import Testing
import SQCore
@testable import SQEditorUI

@Suite struct OpacityLineTests {
    private let fd = Time(1, 30)

    private func clip(opacity: Double = 1) -> Clip {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(2, 1))
        c.animation.opacity = AnimatedProperty(opacity)
        return c
    }

    /// 10 s at 100 points per second; the clip starts at 2 s.
    private var geometry: TimelineGeometry { TimelineGeometry(frameDuration: fd, pointsPerSecond: 100) }
    private var x0: CGFloat { geometry.x(for: Time(2, 1)) }
    private var rect: CGRect { CGRect(x: x0, y: 0, width: 1000, height: 80) }
    private func px(_ seconds: Double) -> CGFloat { x0 + CGFloat(seconds * 100) }

    @Test func laneMapsOpacityToHeight() {
        let lane = OpacityLine.lane(in: rect)
        #expect(OpacityLine.y(forOpacity: 1, in: lane) == lane.minY)
        #expect(OpacityLine.y(forOpacity: 0, in: lane) == lane.maxY)
        #expect(abs(OpacityLine.y(forOpacity: 0.5, in: lane) - lane.midY) < 1e-9)
        #expect(abs(OpacityLine.opacity(forY: lane.midY, in: lane) - 0.5) < 1e-9)
        #expect(OpacityLine.opacity(forY: lane.minY - 50, in: lane) == 1)
        #expect(OpacityLine.opacity(forY: lane.maxY + 50, in: lane) == 0)
    }

    @Test func lineIsVisibleOnlyWhenItHasSomethingToSay() {
        let plain = clip()
        #expect(!OpacityLine.isVisible(clip: plain, selected: false, rowHeight: 80))
        #expect(OpacityLine.isVisible(clip: plain, selected: true, rowHeight: 80))
        #expect(!OpacityLine.isVisible(clip: plain, selected: true, rowHeight: 30))         // row too short
        #expect(OpacityLine.isVisible(clip: clip(opacity: 0.5), selected: false, rowHeight: 80))
        var keyed = plain
        keyed.animation.opacity.track.insert(Keyframe(time: .zero, value: 1))
        #expect(OpacityLine.isVisible(clip: keyed, selected: false, rowHeight: 80))
        var audio = plain; audio.kind = .audio
        #expect(!OpacityLine.isVisible(clip: audio, selected: true, rowHeight: 80))
    }

    @Test func hitFindsLineAndKeys() {
        var c = clip(opacity: 0.5)
        let lane = OpacityLine.lane(in: rect)
        let y = OpacityLine.y(forOpacity: 0.5, in: lane)
        let onLine = OpacityLine.hit(clip: c, clipRect: rect, at: CGPoint(x: px(3), y: y + 2), geometry: geometry)
        guard case .line(let t)? = onLine else { Issue.record("expected a line hit"); return }
        #expect(t == Time(3, 1))                                         // 3 s after the clip start
        #expect(OpacityLine.hit(clip: c, clipRect: rect, at: CGPoint(x: px(3), y: y + 30), geometry: geometry) == nil)
        c.animation.opacity.track.insert(Keyframe(time: Time(4, 1), value: 0.5))
        let key = c.animation.opacity.track.keys[0]
        #expect(OpacityLine.hit(clip: c, clipRect: rect, at: CGPoint(x: px(4), y: y), geometry: geometry) == .key(key.id))
    }

    @Test func cmdClickAddsOneKeyAtTheClickedTimeWithTheShownValue() {
        var c = clip()
        c.animation.opacity = AnimatedProperty(1.0, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: 0), Keyframe(time: Time(10, 1), value: 1)]))
        let lane = OpacityLine.lane(in: rect)
        let y = OpacityLine.y(forOpacity: 0.3, in: lane)                 // the line is at 0.3 after 3 s
        let hit = try! #require(OpacityLine.hit(clip: c, clipRect: rect, at: CGPoint(x: px(3), y: y), geometry: geometry))
        let g = OpacityLineGesture(clip: c, hit: hit, start: CGPoint(x: px(3), y: y), clipRect: rect, geometry: geometry, addKey: true)
        var gesture = g
        let out = gesture.update(to: CGPoint(x: px(3), y: y))              // no movement: the added key stays where it was clicked
        #expect(out.animation.opacity.track.keys.count == 3)
        let added = out.animation.opacity.track.keys.first { $0.time == Time(3, 1) }
        #expect(added != nil && abs(added!.value - 0.3) < 1e-9)
    }

    @Test func dragMovesTheKeyInTimeAndValue() {
        var c = clip()
        c.animation.opacity.track.insert(Keyframe(time: Time(4, 1), value: 0.5))
        let id = c.animation.opacity.track.keys[0].id
        let lane = OpacityLine.lane(in: rect)
        let start = CGPoint(x: px(4), y: OpacityLine.y(forOpacity: 0.5, in: lane))
        var g = OpacityLineGesture(clip: c, hit: .key(id), start: start, clipRect: rect, geometry: geometry, addKey: false)
        let out = g.update(to: CGPoint(x: px(5), y: OpacityLine.y(forOpacity: 0.8, in: lane)))
        let k = out.animation.opacity.track.keys[0]
        #expect(k.time == Time(5, 1) && abs(k.value - 0.8) < 1e-9)
        // Back at the start: the original is restored (the result depends only on the pointer).
        #expect(g.update(to: start).animation.opacity.track.keys[0].time == Time(4, 1))
    }

    @Test func dragOnTheLineWithoutKeysChangesTheClipOpacity() {
        let c = clip(opacity: 0.5)
        let lane = OpacityLine.lane(in: rect)
        let y0 = OpacityLine.y(forOpacity: 0.5, in: lane)
        var g = OpacityLineGesture(clip: c, hit: .line(atLocal: Time(3, 1)), start: CGPoint(x: px(3), y: y0), clipRect: rect,
                                   geometry: geometry, addKey: false)
        let out = g.update(to: CGPoint(x: px(3), y: OpacityLine.y(forOpacity: 0.25, in: lane)))
        #expect(abs(out.animation.opacity.value - 0.25) < 1e-9)
    }
}
