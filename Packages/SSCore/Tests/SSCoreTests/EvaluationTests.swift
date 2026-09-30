import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, src: Int64 = 0, kind: TrackKind = .video) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(src), duration: s(dur)), start: s(start))
}
private func track(_ clips: [Clip], kind: TrackKind = .video, visible: Bool = true,
                   muted: Bool = false, solo: Bool = false) throws -> Track {
    var t = Track(kind: kind, isVisible: visible, isMuted: muted, isSolo: solo)
    for c in clips { try t.overwrite(c) }
    return t
}
private func timeline(_ tracks: Track...) -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks) }

@Suite struct EvaluationTests {
    @Test func gapsYieldNothing() throws {
        let tl = timeline(try track([clip(2, 2)]))
        #expect(tl.videoLayers(at: s(1)).isEmpty)
        #expect(tl.videoLayers(at: s(5)).isEmpty)
        #expect(timeline().videoLayers(at: s(0)).isEmpty)
    }

    @Test func hiddenTrackOmitted() throws {
        let tl = timeline(try track([clip(0, 4)], visible: false), try track([clip(0, 4)]))
        let l = tl.videoLayers(at: s(1))
        #expect(l.count == 1)
        #expect(l[0].track == tl.tracks[1].id)
    }

    @Test func halfOpenEdges() throws {
        let a = clip(0, 2), b = clip(2, 2)
        let tl = timeline(try track([a, b]))
        #expect(tl.videoLayers(at: s(0)).map(\.clip) == [a.id])
        #expect(tl.videoLayers(at: Time(19, 10)).map(\.clip) == [a.id])
        #expect(tl.videoLayers(at: s(2)).map(\.clip) == [b.id])
        #expect(tl.videoLayers(at: s(4)).isEmpty)
    }

    @Test func stackedOrderBottomToTop() throws {
        let tl = timeline(try track([clip(0, 4)]), try track([clip(0, 4)]), try track([clip(1, 2)]))
        #expect(tl.videoLayers(at: s(1)).map(\.track) == tl.tracks.map(\.id))
        #expect(tl.videoLayers(at: s(0)).map(\.track) == [tl.tracks[0].id, tl.tracks[1].id])
    }

    @Test func sourceTimeAfterSlip() throws {
        let c = clip(10, 5, src: 3)   // slipped: source starts at 3 s
        let tl = timeline(try track([c]))
        let l = tl.videoLayers(at: s(12))
        #expect(l.count == 1)
        #expect(l[0].sourceTime == s(5))
        #expect(l[0].media == c.media)
        #expect(tl.videoLayers(at: s(10))[0].sourceTime == s(3))
    }

    @Test func videoTracksIgnoredForAudio() throws {
        let tl = timeline(try track([clip(0, 4)]))
        #expect(tl.audioSegments(in: TimeRange(start: s(0), duration: s(4))).isEmpty)
    }

    @Test func audioClippedToRangeWithSourceStart() throws {
        let c = clip(2, 6, src: 10, kind: .audio)
        let tl = timeline(try track([c], kind: .audio))
        let segs = tl.audioSegments(in: TimeRange(start: s(4), duration: s(10)))
        #expect(segs.count == 1)
        #expect(segs[0].timeline == TimeRange(start: s(4), end: s(8)))
        #expect(segs[0].sourceStart == s(12))
        #expect(segs[0].clip == c.id)
        #expect(segs[0].media == c.media)
        // range fully before / touching the end yields nothing
        #expect(tl.audioSegments(in: TimeRange(start: s(0), duration: s(2))).isEmpty)
        #expect(tl.audioSegments(in: TimeRange(start: s(8), duration: s(2))).isEmpty)
    }

    @Test func audioSpansMultipleClipsAndTracks() throws {
        let tl = timeline(try track([clip(0, 2, kind: .audio), clip(2, 2, kind: .audio)], kind: .audio),
                          try track([clip(1, 2, kind: .audio)], kind: .audio))
        let segs = tl.audioSegments(in: TimeRange(start: s(0), duration: s(4)))
        #expect(segs.count == 3)
    }

    @Test func mutedTrackSilent() throws {
        let tl = timeline(try track([clip(0, 4, kind: .audio)], kind: .audio, muted: true),
                          try track([clip(0, 4, kind: .audio)], kind: .audio))
        let segs = tl.audioSegments(in: TimeRange(start: s(0), duration: s(4)))
        #expect(segs.map(\.track) == [tl.tracks[1].id])
    }

    @Test func soloSilencesOthers() throws {
        let tl = timeline(try track([clip(0, 4, kind: .audio)], kind: .audio),
                          try track([clip(0, 4, kind: .audio)], kind: .audio, solo: true),
                          try track([clip(0, 4, kind: .audio)], kind: .audio, muted: true, solo: true))
        let segs = tl.audioSegments(in: TimeRange(start: s(0), duration: s(4)))
        #expect(segs.map(\.track) == [tl.tracks[1].id])
    }

    @Test func editPointsSortedUnique() throws {
        let tl = timeline(try track([clip(0, 2), clip(2, 3)]), try track([clip(1, 4, kind: .audio)], kind: .audio))
        #expect(tl.editPoints() == [s(0), s(1), s(2), s(5)])
    }

    @Test func durationIsEndOfLastClip() throws {
        #expect(timeline().duration == .zero)
        #expect(timeline(Track(kind: .video)).duration == .zero)
        let tl = timeline(try track([clip(0, 2)]), try track([clip(3, 4, kind: .audio)], kind: .audio))
        #expect(tl.duration == s(7))
    }
}
