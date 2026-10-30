import Foundation
import Testing
@testable import SQCore

@Suite struct TimelineClipIndexTests {
    func s(_ n: Int64) -> Time { Time(n, 1) }

    /// V1 and A1 with `n` linked pairs, 2 s each, back to back; plus an empty V2.
    func make(_ n: Int = 4) -> Timeline {
        var v = Track(kind: .video), a = Track(kind: .audio)
        let v2 = Track(kind: .video)
        for i in 0..<n {
            let link = UUID()
            var cv = Clip(name: "v\(i)", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: s(Int64(i) * 2))
            var ca = Clip(name: "a\(i)", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(2)), start: s(Int64(i) * 2))
            cv.link = link; ca.link = link
            try! v.overwrite(cv); try! a.overwrite(ca)
        }
        return Timeline(name: "T", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v2, v, a])
    }

    /// The index must agree with a full scan for every clip, and know nothing else.
    func expectMatches(_ t: Timeline, _ ix: TimelineClipIndex) {
        var total = 0
        var links: [UUID: [Clip.ID]] = [:]
        for (ti, track) in t.tracks.enumerated() {
            for (ci, c) in track.clips.enumerated() {
                total += 1
                #expect(ix.location(of: c.id) == .init(track: ti, clip: ci, trackID: track.id))
                #expect(ix.trackID(of: c.id) == track.id)
                #expect(ix.clip(c.id, in: t) == c)
                if let l = c.link { links[l, default: []].append(c.id) }
            }
        }
        #expect(ix.count == total)
        for (l, ids) in links { #expect(ix.clips(linkedBy: l) == ids) }
        #expect(ix.location(of: UUID()) == nil)
        #expect(ix.clip(UUID(), in: t) == nil)
        #expect(ix.clips(linkedBy: UUID()).isEmpty)
    }

    @Test func freshTimelineMatchesScan() {
        let t = make()
        expectMatches(t, TimelineClipIndex(t))
        #expect(TimelineClipIndex(Timeline(name: "E", format: t.format, tracks: [])).count == 0)
    }

    @Test func afterMoveAcrossTracks() throws {
        var t = make()
        let id = t.tracks[1].clips[0].id
        try t.move(id, to: s(20), track: t.tracks[0].id)
        let ix = TimelineClipIndex(t)
        expectMatches(t, ix)
        #expect(ix.trackID(of: id) == t.tracks[0].id)
        #expect(ix.location(of: id)?.track == 0)
    }

    @Test func afterMoveWithinTrackReordersPositions() throws {
        var t = make()
        let id = t.tracks[1].clips[0].id
        try t.move(id, to: s(30))
        let ix = TimelineClipIndex(t)
        expectMatches(t, ix)
        #expect(ix.location(of: id)?.clip == t.tracks[1].clips.count - 1)
    }

    @Test func afterSplit() throws {
        var t = make()
        var v = t.tracks[1]
        try v.split(at: s(1))
        t.tracks[1] = v
        let ix = TimelineClipIndex(t)
        expectMatches(t, ix)
        #expect(ix.count == 9)
    }

    @Test func afterTrackInsertAndDelete() {
        var t = make()
        let before = TimelineClipIndex(t)
        t.tracks.insert(Track(kind: .video), at: 0)
        let inserted = TimelineClipIndex(t)
        expectMatches(t, inserted)
        #expect(inserted != before)   // positions shifted by one track
        let id = t.tracks[2].clips[0].id
        #expect(inserted.location(of: id)?.track == 2)

        let removed = t.tracks.remove(at: 2)
        let ix = TimelineClipIndex(t)
        expectMatches(t, ix)
        for c in removed.clips { #expect(!ix.contains(c.id)) }
        #expect(ix.count == 4)
    }

    @Test func afterRippleDelete() throws {
        var t = make()
        let id = t.tracks[1].clips[1].id
        _ = try t.rippleDelete([id])
        let ix = TimelineClipIndex(t)
        expectMatches(t, ix)
        #expect(!ix.contains(id))
    }
}
