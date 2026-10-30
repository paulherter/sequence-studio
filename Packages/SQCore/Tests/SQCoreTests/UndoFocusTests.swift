import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(0), duration: s(dur)), start: s(start))
}
private func timeline(_ clips: [Clip]) -> Timeline {
    Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: clips)])
}

@Suite struct UndoFocusTests {
    @Test func identicalTimelinesHaveNoFocus() {
        let t = timeline([clip(0, 5)])
        #expect(UndoFocus.between(t, t) == nil)
    }

    @Test func changedClipIsFocusedWithItsRange() {
        let a = clip(0, 5), b = clip(10, 5)
        var b2 = b; b2.name = "renamed"
        let f = UndoFocus.between(timeline([a, b]), timeline([a, b2]))
        #expect(f?.clips == [b.id])
        #expect(f?.range == TimeRange(start: s(10), duration: s(5)))
    }

    @Test func movedClipCoversOldAndNewPosition() {
        let a = clip(0, 5)
        var moved = a; moved.start = s(20)
        let f = UndoFocus.between(timeline([a]), timeline([moved]))
        #expect(f?.clips == [a.id])
        #expect(f?.range == TimeRange(start: s(0), end: s(25)))
    }

    @Test func removedClipFocusesRangeButNoClips() {
        let a = clip(0, 5), b = clip(10, 5)
        let f = UndoFocus.between(timeline([a, b]), timeline([a]))
        #expect(f?.clips.isEmpty == true)
        #expect(f?.range == TimeRange(start: s(10), duration: s(5)))
    }

    @Test func addedClipIsFocused() {
        let a = clip(0, 5), b = clip(10, 5)
        let f = UndoFocus.between(timeline([a]), timeline([a, b]))
        #expect(f?.clips == [b.id])
    }

    @Test func playheadStaysWhenInsideRange() {
        let f = UndoFocus(clips: [], range: TimeRange(start: s(10), duration: s(5)))
        #expect(f.playhead(from: s(12)) == nil)
        #expect(f.playhead(from: s(15)) == nil)
    }

    @Test func playheadMovesToRangeStartWhenOutside() {
        let f = UndoFocus(clips: [], range: TimeRange(start: s(10), duration: s(5)))
        #expect(f.playhead(from: s(2)) == s(10))
        #expect(f.playhead(from: s(40)) == s(10))
    }
}
