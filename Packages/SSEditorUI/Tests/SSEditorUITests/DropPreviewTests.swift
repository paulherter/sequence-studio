import CoreGraphics
import Foundation
import SSCore
import Testing
@testable import SSEditorUI

private let fd = Time(1, 24)

@Suite struct DropPreviewTests {
    private func fixture() -> (Timeline, TimelineGeometry, v1: Track, a1: Track) {
        let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 48), start: fd * 100)
        let v1 = Track(kind: .video, clips: [c]), a1 = Track(kind: .audio)
        let t = Timeline(name: "t", frameDuration: fd, tracks: [v1, a1])
        return (t, TimelineGeometry(frameDuration: fd, pointsPerFrame: 10), v1, a1)
    }
    private func pointOn(_ track: Track.ID, frame: Int64, _ t: Timeline, _ g: TimelineGeometry) -> CGPoint {
        let row = g.rows(for: t).first { $0.track == track }!
        return CGPoint(x: g.x(for: fd * frame) + 1, y: row.y + row.height / 2)
    }

    @Test func ghostLengthAndLinkedAudio() {
        let (t, g, v1, a1) = fixture()
        var p = DropPreview()
        p.begin(items: [DropItem(name: "m", duration: fd * 24, hasVideo: true, hasAudio: true)])
        p.update(point: pointOn(v1.id, frame: 10, t, g), insert: false, timeline: t, geometry: g, snapping: false, playhead: .zero)
        #expect(p.ghosts.count == 2)
        #expect(p.ghosts[0].track == v1.id && p.ghosts[1].track == a1.id)
        #expect(p.ghosts[0].range == TimeRange(start: fd * 10, duration: fd * 24))
        #expect(p.commitTarget?.insert == false)
    }

    @Test func commandMeansInsert() {
        let (t, g, v1, _) = fixture()
        var p = DropPreview()
        p.begin(items: [DropItem(name: "m", duration: fd * 24)])
        p.update(point: pointOn(v1.id, frame: 10, t, g), insert: true, timeline: t, geometry: g, snapping: false, playhead: .zero)
        #expect(p.commitTarget?.insert == true)
    }

    @Test func snapsEndToClipStart() {
        let (t, _, v1, _) = fixture()
        let g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 2)   // 8 pt threshold = 4 frames
        var p = DropPreview()
        p.begin(items: [DropItem(name: "m", duration: fd * 24)])
        // Pointer at frame 77 -> end 101, within 4 frames of clip start 100.
        p.update(point: pointOn(v1.id, frame: 77, t, g), insert: false, timeline: t, geometry: g, snapping: true, playhead: .zero)
        #expect(p.start == fd * 76)
        #expect(p.snapTime == fd * 100)
        p.update(point: pointOn(v1.id, frame: 77, t, g), insert: false, timeline: t, geometry: g, snapping: false, playhead: .zero)
        #expect(p.snapTime == nil && p.start >= fd * 76 && p.start <= fd * 78)
    }

    @Test func rulerHidesGhostAndCancelClears() {
        let (t, g, v1, _) = fixture()
        var p = DropPreview()
        p.begin(items: [DropItem(name: "m", duration: fd * 24)])
        p.update(point: pointOn(v1.id, frame: 10, t, g), insert: false, timeline: t, geometry: g, snapping: false, playhead: .zero)
        p.update(point: CGPoint(x: 300, y: 5), insert: false, timeline: t, geometry: g, snapping: false, playhead: .zero)
        #expect(p.ghosts.isEmpty && p.commitTarget == nil)
        p.update(point: pointOn(v1.id, frame: 10, t, g), insert: false, timeline: t, geometry: g, snapping: false, playhead: .zero)
        p.cancel()
        #expect(!p.isActive && p.ghosts.isEmpty && p.commitTarget == nil)
    }

    @Test func itemsGoSequentiallyAndAudioOnlyTargetsAudio() {
        let (t, g, v1, a1) = fixture()
        var p = DropPreview()
        p.begin(items: [DropItem(name: "a", duration: fd * 10, hasVideo: false, hasAudio: true),
                        DropItem(name: "b", duration: fd * 5)])
        p.update(point: pointOn(v1.id, frame: 0, t, g), insert: false, timeline: t, geometry: g, snapping: false, playhead: .zero)
        #expect(p.ghosts.map(\.track) == [a1.id, v1.id])
        #expect(p.ghosts[1].range.start == fd * 10)
    }
}
