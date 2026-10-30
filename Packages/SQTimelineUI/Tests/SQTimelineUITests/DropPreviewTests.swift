#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

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

    @Test func audioMirrorsUpperVideoTrackAndMissingOneIsAGhostOnANewTrack() {
        let v1 = Track(kind: .video, isTargeted: true), v2 = Track(kind: .video), v3 = Track(kind: .video)
        let a1 = Track(kind: .audio, isTargeted: true), a2 = Track(kind: .audio)
        let t = Timeline(name: "t", frameDuration: fd, tracks: [v1, v2, v3, a1, a2])
        let g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 10)
        var p = DropPreview()
        p.begin(items: [DropItem(name: "m", duration: fd * 24, hasVideo: true, hasAudio: true)])
        p.update(point: pointOn(v2.id, frame: 10, t, g), insert: false, timeline: t, geometry: g, snapping: false, playhead: .zero)
        #expect(p.ghosts.map(\.track) == [v2.id, a2.id])
        p.update(point: pointOn(v3.id, frame: 10, t, g), insert: false, timeline: t, geometry: g, snapping: false, playhead: .zero)
        #expect(p.ghosts.count == 2 && p.ghosts[1].newTrackOrdinal == 2 && p.ghosts[1].kind == .audio)
        #expect(p.commitTarget?.track == v3.id)
    }

    @Test func audioOnlyDropOnAudioTrackStaysThere() {
        let (t, g, _, a1) = fixture()
        var p = DropPreview()
        p.begin(items: [DropItem(name: "a", duration: fd * 10, hasVideo: false, hasAudio: true)])
        p.update(point: pointOn(a1.id, frame: 0, t, g), insert: false, timeline: t, geometry: g, snapping: false, playhead: .zero)
        #expect(p.ghosts.map(\.track) == [a1.id])
        #expect(p.commitTarget?.track == a1.id)
    }

    /// Audio-only drag toggle over an audio track: the ghost shows only audio, on that track, and the commit keeps it
    /// (no video ghost the drop would never place, no audio landing on V1's mirrored track instead).
    @Test func audioOnlyStreamsFollowThePointedAudioTrack() {
        var (t, g, _, _) = fixture()
        let a2 = Track(kind: .audio); t.tracks.append(a2)
        var p = DropPreview()
        p.begin(items: [DropItem(name: "m", duration: fd * 24, hasVideo: true, hasAudio: true)], streams: .audioOnly)
        p.update(point: pointOn(a2.id, frame: 10, t, g), insert: false, timeline: t, geometry: g, snapping: false, playhead: .zero)
        #expect(p.ghosts.map(\.track) == [a2.id])
        #expect(p.commitTarget?.track == a2.id)
    }

    @Test func videoOnlyStreamsDrawNoAudioGhost() {
        let (t, g, v1, _) = fixture()
        var p = DropPreview()
        p.begin(items: [DropItem(name: "m", duration: fd * 24, hasVideo: true, hasAudio: true)], streams: .videoOnly)
        p.update(point: pointOn(v1.id, frame: 10, t, g), insert: false, timeline: t, geometry: g, snapping: false, playhead: .zero)
        #expect(p.ghosts.map(\.track) == [v1.id])
    }

    /// A drop that would land on a locked track is refused on release: no ghost (and so no copy cursor) over it.
    @Test func lockedTargetShowsNoGhost() {
        var (t, g, v1, _) = fixture()
        t.tracks[1].isLocked = true                      // A1, where the linked audio would go
        var p = DropPreview()
        p.begin(items: [DropItem(name: "m", duration: fd * 24, hasVideo: true, hasAudio: true)])
        p.update(point: pointOn(v1.id, frame: 10, t, g), insert: false, timeline: t, geometry: g, snapping: false, playhead: .zero)
        #expect(p.ghosts.isEmpty && p.commitTarget == nil)
    }
}
