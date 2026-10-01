import AppKit
import Foundation
import Testing
import SQCore
@testable import SQEditorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)

@Suite struct FadeHandleTests {
    private let clip = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: s(5))
    private let rect = CGRect(x: 100, y: 0, width: 400, height: 60)      // 40 pt per second

    @Test func handlesSitInsideTheClipTopCornersAndMoveWithTheFade() {
        var c = clip
        var p = VolumeLine.fadeHandlePoints(clip: c, clipRect: rect)
        #expect(p.head.x == 106 && p.tail.x == 494 && p.head.y == p.tail.y)
        c.setAudioFadeIn(s(1), frameDuration: fd)
        c.setAudioFadeOut(s(2), frameDuration: fd)
        p = VolumeLine.fadeHandlePoints(clip: c, clipRect: rect)
        #expect(abs(p.head.x - 146) < 1e-9 && abs(p.tail.x - 414) < 1e-9)
    }

    @Test func hitTestFindsTheHandleOnly() {
        let p = VolumeLine.fadeHandlePoints(clip: clip, clipRect: rect)
        #expect(VolumeLine.fadeHandle(clip: clip, clipRect: rect, at: p.head) == .head)
        #expect(VolumeLine.fadeHandle(clip: clip, clipRect: rect, at: p.tail) == .tail)
        #expect(VolumeLine.fadeHandle(clip: clip, clipRect: rect, at: CGPoint(x: 300, y: p.head.y)) == nil)
        #expect(VolumeLine.fadeHandle(clip: clip, clipRect: CGRect(x: 0, y: 0, width: 20, height: 60), at: CGPoint(x: 6, y: 5)) == nil)
    }

    @Test func draggingTheHeadOneSecondMakesTheKeys() {
        let c = VolumeLine.clip(clip, dragging: .head, from: .zero, dx: 40, clipRect: rect, frameDuration: fd)
        let k = c.animation.volume.track.keys
        #expect(k.map(\.time) == [.zero, s(1)] && k.map(\.value) == [0, 1])
        #expect(clip.animation.volume.track.isEmpty)                       // the original is untouched: undo restores it exactly
        let back = VolumeLine.clip(c, dragging: .head, from: s(1), dx: -40, clipRect: rect, frameDuration: fd)
        #expect(back.animation == clip.animation)
    }

    @Test func draggingTheTailGoesTheOtherWayAndSubFrameIsNothing() {
        let c = VolumeLine.clip(clip, dragging: .tail, from: .zero, dx: -80, clipRect: rect, frameDuration: fd)
        #expect(c.audioFadeOut == s(2))
        let tiny = VolumeLine.clip(clip, dragging: .head, from: .zero, dx: 0.5, clipRect: rect, frameDuration: fd)    // 12 ms
        #expect(tiny.animation == clip.animation)
    }

    @Test @MainActor func trackMixDialogRendersWithoutCrashing() {
        let v = TrackMixDialog.makeView(volumeDB: -6, pan: -0.5)
        v.view.layoutSubtreeIfNeeded()
        #expect(v.view.frame.width >= 300)
        #expect(TrackMixDialog.text(pan: -50) == "L 50" && TrackMixDialog.text(pan: 0) == "Center" && TrackMixDialog.text(volumeDB: 3) == "+3.0 dB")
        v.volume.doubleValue = 0.3; _ = v.volume.sendAction(v.volume.action, to: v.volume.target)
        #expect(v.volume.doubleValue == 0)                                  // snaps to unity
    }
}
