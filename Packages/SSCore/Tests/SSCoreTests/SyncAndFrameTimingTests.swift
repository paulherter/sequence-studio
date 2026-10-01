import Foundation
import Testing
@testable import SSCore

/// 29.97 fps: frames are 1001/30000 s, never a whole number of audio samples. Every edit has to keep linked video
/// and audio on the same source frame, and half-open boundaries must not drop or double a frame.
private let fd = Time(1001, 30000)
private func f(_ n: Int64) -> Time { fd * n }

private func linked(start: Int64 = 0, frames: Int64 = 300, srcStart: Int64 = 30) -> (Timeline, Clip, Clip) {
    let media = UUID(), link = UUID()
    let v = Clip(name: "v", media: media, kind: .video, source: TimeRange(start: f(srcStart), duration: f(frames)),
                 start: f(start), link: link, mediaDuration: f(1000))
    let a = Clip(name: "a", media: media, kind: .audio, source: TimeRange(start: f(srcStart), duration: f(frames)),
                 start: f(start), link: link, mediaDuration: f(1000))
    var vt = Track(kind: .video, clips: [], name: "V1"), at = Track(kind: .audio, clips: [], name: "A1")
    try! vt.overwrite(v); try! at.overwrite(a)
    return (Timeline(name: "t", frameDuration: fd, tracks: [vt, at]), v, a)
}

@Suite struct SyncAndFrameTimingTests {
    @Test func razorCutKeepsBothHalvesInSync() throws {
        var (t, _, _) = linked()
        _ = try t.addEdit(at: f(101), tracks: nil)
        #expect(t.tracks.allSatisfy { $0.clips.count == 2 })
        #expect(t.syncOffsets().isEmpty)
        // The cut is on a frame: right half starts exactly there and the source continues without a gap or repeat.
        let right = t.tracks[1].clips[1]
        #expect(right.start == f(101) && right.source.start == f(30 + 101))
        #expect(t.tracks[1].clips[0].timeline.end == right.start)
    }

    @Test func movingTheLinkedPairKeepsSync() throws {
        var (t, v, _) = linked()
        _ = try t.move(v.id, to: f(57), track: nil)
        #expect(t.syncOffsets().isEmpty)
        #expect(t.tracks[0].clips[0].start == f(57) && t.tracks[1].clips[0].start == f(57))
    }

    @Test func trimmingBothHeadsAndTailsKeepsSync() throws {
        var (t, v, _) = linked()
        _ = try t.trim(v.id, edge: .head, by: f(13))
        _ = try t.trim(v.id, edge: .tail, by: f(-7))
        #expect(t.syncOffsets().isEmpty)
        #expect(t.tracks[0].clips[0].source == t.tracks[1].clips[0].source)
    }

    @Test func rippleTrimAndDeleteInOtherTracksKeepSync() throws {
        var (t, v, _) = linked()
        _ = try t.addEdit(at: f(100), tracks: nil)
        let second = t.tracks[0].clips[1]
        _ = try t.rippleDelete([v.id])
        #expect(t.tracks.allSatisfy { $0.clips.count == 1 })
        #expect(t.syncOffsets().isEmpty)
        #expect(t.tracks[0].clips[0].id == second.id && t.tracks[0].clips[0].start == .zero)
    }

    @Test func slipOfOneSideShowsTheBadgeInFrames() throws {
        var (t, v, a) = linked()
        var solo = a; solo.link = nil                      // independent edit (Alt-click selection in Premiere)
        try t.replaceClip(solo)
        _ = try t.slip(a.id, by: f(4))
        var back = t.tracks[1].clips[0]; back.link = v.link
        try t.replaceClip(back)
        #expect(t.syncOffsets()[a.id] == -4 && t.syncOffsets()[v.id] == 4)
    }

    @Test func captionBoundariesAreHalfOpenOnTheFrameGrid() throws {
        var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video)])
        _ = try t.replaceCaptions([CaptionItem(lines: ["a"], range: TimeRange(start: f(30), end: f(60)))])
        #expect(t.captions(at: f(29)).isEmpty)
        #expect(t.captions(at: f(30)).count == 1)           // first frame shows it
        #expect(t.captions(at: f(59)).count == 1)           // last frame shows it
        #expect(t.captions(at: f(60)).isEmpty)              // end frame belongs to the next caption / nothing
        // Exactly 30 frames visible.
        #expect((0..<100).filter { !t.captions(at: f(Int64($0))).isEmpty }.count == 30)
    }

    @Test func splitCaptionOnAFrameGivesAdjacentFrameExactHalves() throws {
        var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video)])
        _ = try t.replaceCaptions([CaptionItem(lines: ["one two three"], range: TimeRange(start: f(10), end: f(70)))])
        let id = t.captionTracks[0].items[0].id
        _ = try t.splitCaption(id, at: f(41))
        let items = t.captionTracks[0].items
        #expect(items[0].range.end == f(41) && items[1].range.start == f(41))
        let visible = (0..<100).filter { !t.captions(at: f(Int64($0))).isEmpty }
        #expect(visible == Array(10..<70))                  // no frame dropped or shown twice by the split
    }

    @Test func playheadSnapsToTheNearestFrameForTextTiming() {
        // 5.0 s is not a whole number of 29.97 frames: snapped it is 150 frames (5.005 s).
        let five = Time(5, 1).snapped(to: fd)
        #expect(five == f(150))
        #expect(Time(1, 100).snapped(to: fd) == .zero)
    }
}
