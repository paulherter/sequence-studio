import Foundation
import Testing
@testable import SQCore

@Suite struct JumpCutTests {
    let fd = Time(1, 30)
    func s(_ n: Int64) -> Time { Time(n, 1) }
    func f(_ n: Int64) -> Time { Time(1, 30) * n }

    /// Linked A/V take on V1/A1, 0...10 s, source 5...15 s of a 60 s file. `withUpper`: V2/A2 exist.
    func make(withUpper: Bool = true, sourceStart: Time = Time(5, 1)) -> (Timeline, v: Clip, a: Clip) {
        let link = UUID(), media = UUID()
        let src = TimeRange(start: sourceStart, duration: s(10))
        let v = Clip(name: "take", media: media, kind: .video, source: src, start: .zero, link: link, mediaDuration: s(60))
        let a = Clip(name: "take", media: media, kind: .audio, source: src, start: .zero, link: link, mediaDuration: s(60))
        var v1 = Track(kind: .video, isTargeted: true), a1 = Track(kind: .audio, isTargeted: true)
        try! v1.overwrite(v); try! a1.overwrite(a)
        var tracks = [v1]
        if withUpper { tracks.append(Track(kind: .video)) }
        tracks.append(a1)
        if withUpper { tracks.append(Track(kind: .audio)) }
        return (Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd), tracks: tracks), v, a)
    }

    func track(_ t: Timeline, _ kind: TrackKind, _ n: Int) -> Track { t.tracks.filter { $0.kind == kind }[n] }

    @Test func movesRestToAlternateTrackWithOverlapAndCrossfade() throws {
        var (t, v, a) = make()
        let moved = try t.jumpCutAlternate(at: s(4), selection: [], overlapFrames: 9)
        #expect(moved.count == 2)
        let v1 = track(t, .video, 0), v2 = track(t, .video, 1), a1 = track(t, .audio, 0), a2 = track(t, .audio, 1)
        // Left halves keep the id, end on the cut.
        #expect(v1.clips.map(\.id) == [v.id]); #expect(v1.clips[0].timeline.end == s(4))
        #expect(a1.clips.map(\.id) == [a.id]); #expect(a1.clips[0].timeline.end == s(4))
        // Right halves on V2/A2, head pulled back 9 frames into the handle, same end, same source frame at the cut.
        let rv = try #require(v2.clips.first), ra = try #require(a2.clips.first)
        #expect(Set(moved) == [rv.id, ra.id])
        #expect(rv.start == s(4) - f(9)); #expect(ra.start == rv.start)
        #expect(rv.timeline.end == s(10)); #expect(ra.timeline.end == s(10))
        #expect(rv.source.start == s(9) - f(9))
        // Sync: both halves share a new link, different from the left's.
        #expect(rv.link != nil); #expect(rv.link == ra.link); #expect(rv.link != v.link)
        // Audio crossfade over the overlap.
        #expect(a1.clips[0].audioFadeOut == f(9))
        #expect(ra.audioFadeIn == f(9))
        #expect(rv.audioFadeIn == .zero)
    }

    @Test func secondJumpCutOnMovedClipGoesBackDown() throws {
        var (t, v, _) = make()
        let moved = try t.jumpCutAlternate(at: s(4), selection: [], overlapFrames: 9)
        let back = try t.jumpCutAlternate(at: s(7), selection: Set(moved), overlapFrames: 9)
        #expect(back.count == 2)
        let v1 = track(t, .video, 0), v2 = track(t, .video, 1), a1 = track(t, .audio, 0), a2 = track(t, .audio, 1)
        #expect(v1.clips.count == 2); #expect(a1.clips.count == 2)
        #expect(v1.clips[0].id == v.id)
        #expect(v1.clips[1].start == s(7) - f(9)); #expect(v1.clips[1].timeline.end == s(10))
        #expect(a1.clips[1].start == v1.clips[1].start)
        #expect(v2.clips.count == 1); #expect(v2.clips[0].timeline.end == s(7))
        #expect(a2.clips[0].audioFadeOut == f(9)); #expect(a1.clips[1].audioFadeIn == f(9))
        #expect(v1.clips[1].link == a1.clips[1].link)
    }

    @Test func overlapLimitedByHeadHandle() throws {
        var (t, _, _) = make(sourceStart: .zero)
        // Source starts at 0: the right half has only 4 frames before the cut at 4 frames.
        _ = try t.jumpCutAlternate(at: f(4), selection: [], overlapFrames: 9)
        let rv = try #require(track(t, .video, 1).clips.first)
        #expect(rv.start == .zero); #expect(rv.source.start == .zero)
        #expect(track(t, .audio, 1).clips[0].audioFadeIn == f(4))
    }

    @Test func overlapLimitedByClipOnAlternateTrack() throws {
        var (t, _, _) = make()
        let broll = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(3) + f(27)), start: .zero)
        let vi = t.tracks.firstIndex { $0.kind == .video && $0.clips.isEmpty }!
        try t.tracks[vi].overwrite(broll)            // ends 3 frames before the cut
        _ = try t.jumpCutAlternate(at: s(4), selection: [], overlapFrames: 9)
        let v2 = track(t, .video, 1)
        #expect(v2.clips.count == 2); #expect(v2.clips[1].start == s(4) - f(3))
        // The whole group uses the same overlap: audio stays in sync.
        #expect(track(t, .audio, 1).clips[0].start == s(4) - f(3))
        #expect(track(t, .audio, 0).clips[0].audioFadeOut == f(3))
    }

    @Test func clipUnderCutOnAlternateTrackIsRefused() throws {
        var (t, _, _) = make()
        let broll = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: s(5))
        let vi = t.tracks.firstIndex { $0.kind == .video && $0.clips.isEmpty }!
        try t.tracks[vi].overwrite(broll)
        let before = t
        #expect(throws: EditError.collision) { try t.jumpCutAlternate(at: s(4), selection: [], overlapFrames: 9) }
        #expect(t == before)
    }

    @Test func lockedTracksAreRefused() throws {
        var (t, _, _) = make()
        let up = t.tracks.firstIndex { $0.kind == .audio && $0.clips.isEmpty }!
        t.tracks[up].isLocked = true
        let before = t
        #expect(throws: EditError.trackLocked) { try t.jumpCutAlternate(at: s(4), selection: [], overlapFrames: 9) }
        #expect(t == before)

        var (u, _, _) = make()
        for i in u.tracks.indices where !u.tracks[i].clips.isEmpty { u.tracks[i].isLocked = true }
        #expect(throws: EditError.trackLocked) { try u.jumpCutAlternate(at: s(4), selection: [], overlapFrames: 9) }
    }

    @Test func linkedPartnerOnLockedTrackRefusesTheWholeCut() throws {
        var (t, _, _) = make()
        let ai = t.tracks.firstIndex { $0.kind == .audio && !$0.clips.isEmpty }!
        t.tracks[ai].isLocked = true
        t.tracks[ai].isTargeted = false
        #expect(throws: EditError.trackLocked) { try t.jumpCutAlternate(at: s(4), selection: [], overlapFrames: 9) }
    }

    @Test func missingAlternateTracksAreCreated() throws {
        var (t, _, _) = make(withUpper: false)
        _ = try t.jumpCutAlternate(at: s(4), selection: [], overlapFrames: 9)
        #expect(t.tracks.filter { $0.kind == .video }.count == 2)
        #expect(t.tracks.filter { $0.kind == .audio }.count == 2)
        #expect(track(t, .video, 1).clips.count == 1); #expect(track(t, .audio, 1).clips.count == 1)
    }

    @Test func zeroOverlapIsAHardCutWithoutFades() throws {
        var (t, _, _) = make()
        _ = try t.jumpCutAlternate(at: s(4), selection: [], overlapFrames: 0)
        #expect(track(t, .video, 1).clips[0].start == s(4))
        #expect(track(t, .audio, 0).clips[0].audioFadeOut == .zero)
        #expect(track(t, .audio, 1).clips[0].audioFadeIn == .zero)
    }

    @Test func noClipUnderPlayheadThrows() throws {
        var (t, _, _) = make()
        #expect(throws: EditError.clipNotFound) { try t.jumpCutAlternate(at: s(20), selection: [], overlapFrames: 9) }
        #expect(throws: EditError.clipNotFound) { try t.jumpCutAlternate(at: .zero, selection: [], overlapFrames: 9) }
    }

    @Test func tailFadeTransitionMovesWithTheRest() throws {
        var (t, v, _) = make()
        let vi = t.tracks.firstIndex { $0.clips.contains { $0.id == v.id } }!
        t.tracks[vi].transitions = [Transition(kind: .crossDissolve, duration: f(10), outgoing: v.id, incoming: nil)]
        let moved = try t.jumpCutAlternate(at: s(4), selection: [], overlapFrames: 9)
        #expect(t.tracks[vi].transitions.isEmpty)
        let v2 = track(t, .video, 1)
        #expect(v2.transitions.count == 1)
        #expect(moved.contains(try #require(v2.transitions[0].outgoing)))
    }

    // MARK: Review fixes

    @Test func overlapNeverReachesBeforeTheLeftHalf() throws {
        // Take starts at 1 s (cut-out material before it in the file); cutting 5 frames in allows only 5 frames of overlap.
        let link = UUID(), media = UUID(), src = TimeRange(start: s(5), duration: s(10))
        let v = Clip(name: "take", media: media, kind: .video, source: src, start: s(1), link: link, mediaDuration: s(60))
        let a = Clip(name: "take", media: media, kind: .audio, source: src, start: s(1), link: link, mediaDuration: s(60))
        var v1 = Track(kind: .video, isTargeted: true), a1 = Track(kind: .audio, isTargeted: true)
        try v1.overwrite(v); try a1.overwrite(a)
        var t = Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd),
                         tracks: [v1, Track(kind: .video), a1, Track(kind: .audio)])
        _ = try t.jumpCutAlternate(at: s(1) + f(5), selection: [], overlapFrames: 9)
        let rv = try #require(track(t, .video, 1).clips.first), ra = try #require(track(t, .audio, 1).clips.first)
        #expect(rv.start == s(1)); #expect(rv.source.start == s(5))
        #expect(ra.start == s(1))
        #expect(track(t, .audio, 0).clips[0].audioFadeOut == f(5)); #expect(ra.audioFadeIn == f(5))
    }

    /// Video V1 linked to A1 + A2 (dual mono, Premiere imports).
    func makeDualMono() -> Timeline {
        let link = UUID(), media = UUID(), src = TimeRange(start: s(5), duration: s(10))
        let v = Clip(name: "take", media: media, kind: .video, source: src, start: .zero, link: link, mediaDuration: s(60))
        var v1 = Track(kind: .video, isTargeted: true), a1 = Track(kind: .audio, isTargeted: true), a2 = Track(kind: .audio)
        try! v1.overwrite(v)
        try! a1.overwrite(Clip(name: "L", media: media, kind: .audio, source: src, start: .zero, link: link, mediaDuration: s(60)))
        try! a2.overwrite(Clip(name: "R", media: media, kind: .audio, source: src, start: .zero, link: link, mediaDuration: s(60)))
        return Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd),
                        tracks: [v1, Track(kind: .video), a1, a2])
    }

    @Test func dualMonoMovesBothChannelsToTheNextAudioPairAndBack() throws {
        var t = makeDualMono()
        let moved = try t.jumpCutAlternate(at: s(4), selection: [], overlapFrames: 9)
        #expect(moved.count == 3)
        #expect(t.tracks.filter { $0.kind == .audio }.count == 4)          // A3 + A4 created
        let a3 = track(t, .audio, 2), a4 = track(t, .audio, 3)
        #expect(a3.clips.map(\.name) == ["L"]); #expect(a4.clips.map(\.name) == ["R"])   // channel order kept
        #expect(a3.clips[0].start == s(4) - f(9)); #expect(a4.clips[0].start == a3.clips[0].start)
        #expect(track(t, .video, 1).clips[0].start == a3.clips[0].start)
        #expect(a3.clips[0].link == track(t, .video, 1).clips[0].link)
        #expect(track(t, .audio, 0).clips[0].audioFadeOut == f(9)); #expect(track(t, .audio, 1).clips[0].audioFadeOut == f(9))

        let back = try t.jumpCutAlternate(at: s(7), selection: Set(moved), overlapFrames: 9)
        #expect(back.count == 3)
        #expect(track(t, .audio, 0).clips.map(\.name) == ["L", "L"]); #expect(track(t, .audio, 1).clips.map(\.name) == ["R", "R"])
        #expect(track(t, .video, 0).clips.count == 2)
    }

    @Test func secondPressAtTheSamePlayheadIsRefused() throws {
        var (t, _, _) = make()
        let moved = try t.jumpCutAlternate(at: s(4), selection: [], overlapFrames: 9)
        let after = t
        #expect(t.jumpCutCandidates(at: s(4), selection: Set(moved)).isEmpty)
        #expect(t.jumpCutCandidates(at: s(4), selection: []).isEmpty)
        #expect(t.isJumpCut(at: s(4), selection: Set(moved)))
        #expect(throws: EditError.clipNotFound) { try t.jumpCutAlternate(at: s(4), selection: Set(moved), overlapFrames: 9) }
        #expect(throws: EditError.clipNotFound) { try t.jumpCutAlternate(at: s(4), selection: [], overlapFrames: 9) }
        #expect(t == after)
        // A little later it cuts again.
        #expect(!t.jumpCutCandidates(at: s(4) + f(1), selection: []).isEmpty)
    }

    @Test func withoutSelectionTheTakeOnTheAlternateTrackIsFound() throws {
        var (t, v, _) = make()
        _ = try t.jumpCutAlternate(at: s(4), selection: [], overlapFrames: 9)
        // Nothing selected, V1/A1 targeted but empty at 7 s: their pair partners V2/A2 hold the take.
        let back = try t.jumpCutAlternate(at: s(7), selection: [], overlapFrames: 9)
        #expect(back.count == 2)
        let v1 = track(t, .video, 0)
        #expect(v1.clips.count == 2); #expect(v1.clips[0].id == v.id); #expect(v1.clips[1].start == s(7) - f(9))
        #expect(track(t, .audio, 0).clips.count == 2)
    }

    @Test func targetedTrackWithAClipUnderThePlayheadWins() throws {
        var (t, _, _) = make()
        // B-roll on V2 under the playhead does not get picked while V1 (targeted) holds the take.
        let broll = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(1)), start: s(1))
        let vi = t.tracks.firstIndex { $0.kind == .video && $0.clips.isEmpty }!
        try t.tracks[vi].overwrite(broll)
        let ids = t.jumpCutCandidates(at: s(1) + f(15), selection: [])
        #expect(!ids.contains(broll.id))
    }

    @Test func defaultOverlapIsAboutPointThreeSeconds() {
        #expect(JumpCut.defaultOverlapFrames(frameDuration: Time(1, 30)) == 9)
        #expect(JumpCut.defaultOverlapFrames(frameDuration: Time(1, 25)) == 7)
        #expect(JumpCut.defaultOverlapFrames(frameDuration: Time(1001, 60000)) == 17)
    }
}
