import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, src: Int64 = 0, kind: TrackKind = .video,
                  link: UUID? = nil, media: Int64? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(src), duration: s(dur)),
         start: s(start), link: link, mediaDuration: media.map(s))
}
private func track(_ clips: [Clip], kind: TrackKind = .video, locked: Bool = false) throws -> Track {
    var t = Track(kind: kind, isLocked: locked)
    for c in clips { try t.overwrite(c) }
    return t
}
private func timeline(_ tracks: Track...) -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks) }

@Suite struct TrimTests {
    @Test func shortenTailLeavesGap() throws {
        let a = clip(0, 4), b = clip(4, 2)
        var tl = timeline(try track([a, b]))
        #expect(try tl.trim(a.id, edge: .tail, by: s(-1)) == s(-1))
        #expect(tl.tracks[0].clips[0].timeline == TimeRange(start: s(0), duration: s(3)))
        #expect(tl.tracks[0].clips[1].start == s(4))
    }
    @Test func headTrimAdvancesStartAndSource() throws {
        let a = clip(2, 4, src: 1)
        var tl = timeline(try track([a]))
        #expect(try tl.trim(a.id, edge: .head, by: s(1)) == s(1))
        let c = tl.tracks[0].clips[0]
        #expect(c.start == s(3) && c.source == TimeRange(start: s(2), duration: s(3)))
    }
    @Test func extendTailClampedByNeighbourAndMedia() throws {
        let a = clip(0, 2, media: 10), b = clip(5, 1)
        var tl = timeline(try track([a, b]))
        #expect(try tl.trim(a.id, edge: .tail, by: s(9)) == s(3))
        let c = clip(0, 2, media: 4)
        var t2 = timeline(try track([c]))
        #expect(try t2.trim(c.id, edge: .tail, by: s(9)) == s(2))
    }
    @Test func extendHeadClampedBySourceStartNeighbourAndZero() throws {
        let a = clip(3, 2, src: 5), p = clip(0, 2)
        var tl = timeline(try track([p, a]))
        #expect(try tl.trim(a.id, edge: .head, by: s(-9)) == s(-1))     // neighbor end 2
        let b = clip(1, 2, src: 4)
        var t2 = timeline(try track([b]))
        #expect(try t2.trim(b.id, edge: .head, by: s(-9)) == s(-1))     // timeline start 0
        let c = clip(5, 2, src: 1)
        var t3 = timeline(try track([c]))
        #expect(try t3.trim(c.id, edge: .head, by: s(-9)) == s(-1))     // source start 0
    }
    @Test func emptyRefused() throws {
        let a = clip(0, 2)
        var tl = timeline(try track([a]))
        #expect(throws: EditError.emptyClip) { try tl.trim(a.id, edge: .tail, by: s(-2)) }
    }
    @Test func partnerFollowsAndMostRestrictiveWins() throws {
        let link = UUID()
        let v = clip(0, 2, link: link), au = clip(0, 2, kind: .audio, link: link, media: 3)
        var tl = timeline(try track([v]), try track([au], kind: .audio))
        #expect(try tl.trim(v.id, edge: .tail, by: s(5)) == s(1))
        #expect(tl.tracks[0].clips[0].source.duration == s(3))
        #expect(tl.tracks[1].clips[0].source.duration == s(3))
    }
    @Test func lockedPartnerTrackRefusesAndNothingChanges() throws {
        let link = UUID()
        let v = clip(0, 2, link: link), au = clip(0, 2, kind: .audio, link: link)
        let tl0 = timeline(try track([v]), try track([au], kind: .audio, locked: true))
        var tl = tl0
        #expect(throws: EditError.trackLocked) { try tl.trim(v.id, edge: .tail, by: s(1)) }
        #expect(tl == tl0)
    }
}

@Suite struct RollTests {
    @Test func movesCutBothWays() throws {
        let a = clip(0, 3, media: 10), b = clip(3, 3, src: 2)
        var tl = timeline(try track([a, b]))
        #expect(try tl.roll(a.id, by: s(1)) == s(1))
        #expect(tl.tracks[0].clips[0].timeline.end == s(4))
        #expect(tl.tracks[0].clips[1].start == s(4) && tl.tracks[0].clips[1].source.start == s(3))
        #expect(try tl.roll(a.id, by: s(-2)) == s(-2))
        #expect(tl.tracks[0].clips[1].start == s(2) && tl.tracks[0].clips[1].source.start == s(1))
        #expect(tl.tracks.allSatisfy { $0.isConsistent })
    }
    @Test func clampedByMedia() throws {
        let a = clip(0, 3, media: 4), b = clip(3, 3, src: 1)
        var tl = timeline(try track([a, b]))
        #expect(try tl.roll(a.id, by: s(5)) == s(1))                    // left media
        #expect(try tl.roll(a.id, by: s(-5)) == s(-2))                  // right source start now 2
    }
    @Test func emptyAndNoAdjacent() throws {
        let a = clip(0, 2), b = clip(2, 2, src: 5), c = clip(5, 1)
        var tl = timeline(try track([a, b, c]))
        #expect(throws: EditError.emptyClip) { try tl.roll(a.id, by: s(2)) }
        #expect(throws: EditError.emptyClip) { try tl.roll(a.id, by: s(-2)) }
        #expect(throws: EditError.collision) { try tl.roll(b.id, by: s(1)) }
    }
    @Test func partnersRollWhenTheyHaveTheSameCut() throws {
        let link = UUID()
        let v = clip(0, 3, link: link, media: 10), au = clip(0, 3, kind: .audio, link: link, media: 10)
        let v2 = clip(3, 2, src: 2), au2 = clip(3, 2, src: 2, kind: .audio)
        var tl = timeline(try track([v, v2]), try track([au, au2], kind: .audio))
        #expect(try tl.roll(v.id, by: s(1)) == s(1))
        #expect(tl.tracks[1].clips[0].timeline.end == s(4) && tl.tracks[1].clips[1].start == s(4))
    }
    @Test func partnerWithoutNeighbourFollowsWithItsOwnEdge() throws {
        let link = UUID()
        let v = clip(0, 3, link: link, media: 10), au = clip(0, 3, kind: .audio, link: link, media: 10)
        var tl = timeline(try track([v, clip(3, 2, src: 2)]), try track([au], kind: .audio))
        #expect(try tl.roll(v.id, by: s(1)) == s(1))
        #expect(tl.tracks[1].clips[0].timeline.end == s(4))                  // stays in sync with the cut
        #expect(try tl.roll(v.id, by: s(-2)) == s(-2))
        #expect(tl.tracks[1].clips[0].timeline.end == s(2))
    }
    @Test func rightClipPartnerWithGapBeforeItFollows() throws {
        let link = UUID()
        let a = clip(0, 10, media: 20), b = clip(10, 4, src: 2, link: link)
        let bAudio = clip(10, 4, src: 2, kind: .audio, link: link), aAudio = clip(0, 8, kind: .audio, media: 20)
        var tl = timeline(try track([a, b]), try track([aAudio, bAudio], kind: .audio))
        #expect(try tl.roll(a.id, by: s(-1)) == s(-1))
        #expect(tl.tracks[0].clips[1].start == s(9))
        #expect(tl.tracks[1].clips[1].start == s(9))                         // b follows B, its head moved too
        #expect(tl.tracks.allSatisfy { $0.isConsistent })
    }
    @Test func partnerMediaAndGapLimitTheRoll() throws {
        let link = UUID()
        let v = clip(0, 3, link: link, media: 10), au = clip(0, 3, kind: .audio, link: link, media: 4)
        var tl = timeline(try track([v, clip(3, 2, src: 2)]), try track([au], kind: .audio))
        #expect(try tl.roll(v.id, by: s(5)) == s(1))                          // audio has one second of media left
        let au2 = clip(0, 3, kind: .audio, link: link, media: 10), next = clip(4, 1, kind: .audio)
        var tl2 = timeline(try track([v, clip(3, 2, src: 2)]), try track([au2, next], kind: .audio))
        #expect(try tl2.roll(v.id, by: s(3)) == s(1))                         // the next audio clip starts at 4
        #expect(tl2.tracks.allSatisfy { $0.isConsistent })
    }
    @Test func lockedRefuses() throws {
        let a = clip(0, 2), b = clip(2, 2)
        let tl0 = timeline(try track([a, b], locked: true))
        var tl = tl0
        #expect(throws: EditError.trackLocked) { try tl.roll(a.id, by: s(1)) }
        #expect(tl == tl0)
    }
}

@Suite struct SlipTests {
    @Test func slipsAndClamps() throws {
        let a = clip(2, 3, src: 1, media: 8)
        var tl = timeline(try track([a]))
        #expect(try tl.slip(a.id, by: s(2)) == s(2))
        #expect(tl.tracks[0].clips[0].source.start == s(3) && tl.tracks[0].clips[0].start == s(2))
        #expect(try tl.slip(a.id, by: s(9)) == s(2))                    // 8 - 3 - 3
        #expect(try tl.slip(a.id, by: s(-9)) == s(-5))                  // back to 0
    }
    @Test func partnerFollowsWithTightestClamp() throws {
        let link = UUID()
        let v = clip(0, 2, src: 1, link: link), au = clip(0, 2, src: 0, kind: .audio, link: link)
        var tl = timeline(try track([v]), try track([au], kind: .audio))
        #expect(try tl.slip(v.id, by: s(-1)) == s(0))                   // audio at 0
        #expect(try tl.slip(v.id, by: s(2)) == s(2))
        #expect(tl.tracks[1].clips[0].source.start == s(2))
    }
    @Test func lockedRefuses() throws {
        let a = clip(0, 2, src: 1)
        let tl0 = timeline(try track([a], locked: true))
        var tl = tl0
        #expect(throws: EditError.trackLocked) { try tl.slip(a.id, by: s(1)) }
        #expect(tl == tl0)
    }
}

@Suite struct MoveTests {
    @Test func movesIntoGap() throws {
        let a = clip(0, 2)
        var tl = timeline(try track([a, clip(6, 1)]))
        #expect(try tl.move(a.id, to: s(3)) == s(3))
        #expect(tl.tracks[0].clips.map(\.start) == [s(3), s(6)])
    }
    @Test func overwritesCoveredClips() throws {
        let a = clip(0, 2), b = clip(3, 4, src: 0)
        var tl = timeline(try track([a, b]))
        try tl.move(a.id, to: s(4))                                     // covers 4..6 of b (3..7)
        let cs = tl.tracks[0].clips
        #expect(cs.count == 3)
        #expect(cs[0].timeline == TimeRange(start: s(3), duration: s(1)))
        #expect(cs[1].id == a.id && cs[1].start == s(4))
        #expect(cs[2].timeline == TimeRange(start: s(6), duration: s(1)) && cs[2].source.start == s(3))
        #expect(tl.tracks.allSatisfy { $0.isConsistent })
    }
    @Test func clampedAtZeroIncludingPartners() throws {
        let link = UUID()
        let v = clip(4, 2, link: link), au = clip(2, 2, kind: .audio, link: link)
        var tl = timeline(try track([v]), try track([au], kind: .audio))
        #expect(try tl.move(v.id, to: s(-5)) == s(-2))
        #expect(tl.tracks[0].clips[0].start == s(2) && tl.tracks[1].clips[0].start == s(0))
    }
    @Test func partnerKeepsTrackPrimaryChangesTrack() throws {
        let link = UUID()
        let v = clip(0, 2, link: link), au = clip(0, 2, kind: .audio, link: link)
        let v1 = try track([v]), v2 = try track([])
        var tl = timeline(v1, v2, try track([au], kind: .audio))
        #expect(try tl.move(v.id, to: s(5), track: v2.id) == s(5))
        #expect(tl.tracks[0].clips.isEmpty)
        #expect(tl.tracks[1].clips.map(\.start) == [s(5)])
        #expect(tl.tracks[2].clips.map(\.start) == [s(5)])
    }
    @Test func wrongKindAndLockedTargets() throws {
        let a = clip(0, 2)
        let audio = try track([], kind: .audio), lockedV = try track([], locked: true)
        let tl0 = timeline(try track([a]), audio, lockedV)
        var tl = tl0
        #expect(throws: EditError.wrongTrackKind) { try tl.move(a.id, to: s(1), track: audio.id) }
        #expect(throws: EditError.trackLocked) { try tl.move(a.id, to: s(1), track: lockedV.id) }
        #expect(tl == tl0)
    }
    @Test func lockedOwnOrPartnerTrackRefuses() throws {
        let link = UUID()
        let v = clip(0, 2, link: link), au = clip(0, 2, kind: .audio, link: link)
        let tl0 = timeline(try track([v]), try track([au], kind: .audio, locked: true))
        var tl = tl0
        #expect(throws: EditError.trackLocked) { try tl.move(v.id, to: s(3)) }
        #expect(tl == tl0)
    }
    @Test func unknownClip() {
        var tl = timeline(Track(kind: .video))
        #expect(throws: EditError.clipNotFound) { try tl.move(UUID(), to: s(1)) }
    }
}
