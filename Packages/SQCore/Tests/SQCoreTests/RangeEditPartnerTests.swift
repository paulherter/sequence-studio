import Foundation
import Testing
@testable import SQCore

/// Clear Range (`lift`) and Delete Range (`extract`) through a linked pair with only the picture's track targeted:
/// the unlocked, untargeted partner is cut with its picture (one shared rule, `Timeline.clearRange`), the pieces on each
/// side stay linked together, locked tracks are untouched. Fast Cut and the batch path (`removeCuts`) agree.
@Suite struct RangeEditPartnerTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }
    private var range: TimeRange { TimeRange(start: Time(10, 1), duration: Time(10, 1)) }

    private func clip(_ kind: TrackKind, _ start: Int64, _ end: Int64, link: UUID? = nil, media: UUID = UUID(), name: String) -> Clip {
        Clip(name: name, media: media, kind: kind, source: TimeRange(start: s(30), duration: s(end - start)), start: s(start),
             link: link, mediaDuration: s(200))
    }
    private func spans(_ t: Track) -> [[Int64]] {
        t.clips.map { [$0.start.value / $0.start.timescale, $0.timeline.end.value / $0.timeline.end.timescale] }
    }
    private func bytes(_ t: Timeline) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return try e.encode(t)
    }

    /// V1: linked picture 0-30. A1: its sound 0-30 and a later unlinked clip. A2 (locked): another linked sound.
    /// A3: unlinked music.
    private func pair() throws -> Timeline {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio), a2 = Track(kind: .audio), a3 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        try a1.overwrite(clip(.audio, 0, 30, link: l, media: m, name: "A"))
        try a1.overwrite(clip(.audio, 40, 50, name: "later"))
        try a2.overwrite(clip(.audio, 0, 30, link: l, media: m, name: "locked"))
        a2.isLocked = true
        try a3.overwrite(clip(.audio, 5, 25, name: "music"))
        return Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1, a2, a3])
    }

    private func expectLinks(_ t: Timeline) {
        let v = t.tracks[0].clips, a = t.tracks[1].clips
        guard v.count >= 2, a.count >= 2 else { Issue.record("partner not cut"); return }
        #expect(v[0].link != nil && v[0].link == a[0].link)      // left pieces together
        #expect(v[1].link != nil && v[1].link == a[1].link)      // right pieces together
        #expect(v[0].link != v[1].link)
    }

    // MARK: Clear Range (lift)

    @Test func liftCutsTheUntargetedPartnerAndLeavesAGap() throws {
        let base = try pair()
        var t = base
        try t.lift(range, tracks: [t.tracks[0].id])
        #expect(spans(t.tracks[0]) == [[0, 10], [20, 30]])
        #expect(spans(t.tracks[1]) == [[0, 10], [20, 30], [40, 50]])     // cut at the same points, nothing rippled
        expectLinks(t)
        #expect(t.tracks[1].clips[0].id == base.tracks[1].clips[0].id)   // the left piece keeps its identity
        #expect(t.tracks[1].clips.last?.id == base.tracks[1].clips.last?.id)
        #expect(t.tracks[2] == base.tracks[2])                           // locked: untouched
        #expect(t.tracks[3] == base.tracks[3])                           // unlinked, untargeted: untouched
    }

    /// The range swallows the picture's tail (no right piece, no new link): only partners of a clip cut in two are cut.
    @Test func liftLeavesAnUntargetedPartnerAloneWhenThePictureIsNotCutInTwo() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 0, 15, link: l, media: m, name: "V"))
        try a1.overwrite(clip(.audio, 0, 15, link: l, media: m, name: "A"))
        let base = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1])
        var t = base, e = base
        try t.lift(range, tracks: [t.tracks[0].id])
        #expect(spans(t.tracks[0]) == [[0, 10]])
        #expect(t.tracks[1] == base.tracks[1])
        try e.extract(range, tracks: [e.tracks[0].id])
        #expect(e.tracks[1] == base.tracks[1])                           // the same rule in Delete Range
    }

    @Test func liftGivesALaterPartnerTheLinkOfTheRightPiece() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        try a1.overwrite(clip(.audio, 22, 30, link: l, media: m, name: "A"))
        var t = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1])
        try t.lift(range, tracks: [t.tracks[0].id])
        #expect(spans(t.tracks[1]) == [[22, 30]])
        #expect(t.tracks[1].clips[0].link == t.tracks[0].clips[1].link)
        #expect(t.tracks[0].clips[0].link == l && t.tracks[0].clips[1].link != l)
    }

    @Test func liftMovesThePartnersTailTransitionToTheRightPiece() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        let a = clip(.audio, 0, 30, link: l, media: m, name: "A"), b = clip(.audio, 30, 40, name: "B")
        try a1.overwrite(a); try a1.overwrite(b)
        a1.transitions = [Transition(kind: .constantPower, duration: s(1), outgoing: a.id, incoming: b.id)]
        var t = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1])
        try t.lift(range, tracks: [t.tracks[0].id])
        #expect(t.tracks[1].clips.count == 3)
        #expect(t.tracks[1].transitions.first?.outgoing == t.tracks[1].clips.dropFirst().first?.id)
    }

    /// Delete Range is Clear Range plus the ripple: both leave the same pieces.
    @Test func liftAndExtractCutTheSamePieces() throws {
        let base = try pair()
        var l = base, e = base
        try l.lift(range, tracks: [l.tracks[0].id])
        try e.extract(range, tracks: [e.tracks[0].id])
        for i in 0..<2 {
            #expect(l.tracks[i].clips.map(\.source) == e.tracks[i].clips.map(\.source))
            #expect(l.tracks[i].clips.map(\.duration) == e.tracks[i].clips.map(\.duration))
        }
        expectLinks(e)
        #expect(spans(e.tracks[1]) == [[0, 10], [10, 20], [30, 40]])
        #expect(e.tracks[2] == base.tracks[2])
    }

    @Test func undoRestoresTheExactSnapshot() throws {
        let base = try pair()
        let v1 = base.tracks[0].id, r = range
        let edits: [(inout Timeline) throws -> Void] = [
            { try $0.lift(r, tracks: [v1]) },
            { try $0.extract(r, tracks: [v1]) },
            { try $0.removeCuts([r], tracks: [v1]) },
        ]
        for edit in edits {
            var hist = History(base, limit: 10)
            try hist.commit("edit", edit)
            let after = hist.current
            #expect(after != base)
            #expect(after.tracks[1].clips.count == 3)
            let undone = hist.undo(); #expect(undone)
            #expect(hist.current == base)
            #expect(try bytes(hist.current) == bytes(base))
            let redone = hist.redo(); #expect(redone)
            #expect(hist.current == after)
        }
    }

    @Test func aRefusedLiftChangesNothing() throws {
        var t = try pair()
        let before = t, r = range
        #expect(throws: EditError.trackLocked) { try t.lift(r, tracks: [t.tracks[0].id, t.tracks[2].id]) }
        #expect(t == before)
    }

    // MARK: Batch path

    /// `removeCuts` (batch) equals one `extract` per cut from the last, with an untargeted partner on a sync-locked track.
    @Test func removeCutsMatchesExtractPerCutForAnUntargetedPartner() throws {
        let base = try pair()
        let cuts = [TimeRange(start: s(4), duration: s(3)), range, TimeRange(start: s(24), duration: s(2))]
        var one = base, batch = base
        var removed = Time.zero
        for c in cuts.reversed() { removed = removed + (try one.extract(c, tracks: [one.tracks[0].id])) }
        let got = try batch.removeCuts(cuts, tracks: [batch.tracks[0].id])
        #expect(got == removed)
        for i in batch.tracks.indices {
            #expect(spans(batch.tracks[i]) == spans(one.tracks[i]))
            #expect(batch.tracks[i].clips.map(\.source) == one.tracks[i].clips.map(\.source))
        }
        // Each picture piece is linked with the sound piece under it, and with no other piece.
        let v = batch.tracks[0].clips, a = batch.tracks[1].clips
        #expect(v.count == 4 && a.count == 5)
        for i in v.indices where i < a.count {
            #expect(spans(batch.tracks[0])[i] == spans(batch.tracks[1])[i])
            #expect(v[i].link != nil && v[i].link == a[i].link)
        }
        #expect(Set(v.compactMap(\.link)).count == v.count)
        #expect(batch.tracks[2] == base.tracks[2])
    }

    // MARK: Fast Cut

    /// V1 (main): unlinked 0-40. V2: linked picture 0-30 with its sound on the untargeted A1.
    private func fastCut() throws -> Timeline {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), v2 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 0, 40, name: "main"))
        try v2.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        try a1.overwrite(clip(.audio, 0, 30, link: l, media: m, name: "A"))
        var t = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, v2, a1])
        t.setEditMode(.magnetic)
        return t
    }

    @Test func fastCutClearRangeCutsTheUntargetedPartner() throws {
        var t = try fastCut()
        #expect(t.isFastCut)
        try t.magneticClearRange(range, tracks: [t.tracks[1].id])
        #expect(spans(t.tracks[0]) == [[0, 40]])
        #expect(spans(t.tracks[1]) == [[0, 10], [20, 30]])
        #expect(spans(t.tracks[2]) == [[0, 10], [20, 30]])
        #expect(t.tracks[1].clips.last?.link == t.tracks[2].clips.last?.link)
        #expect(t.tracks[1].clips.first?.link == t.tracks[2].clips.first?.link)
    }

    @Test func fastCutDeleteRangeKeepsTheUntargetedPartnerInSync() throws {
        var t = try fastCut()
        _ = try t.magneticExtract(range, tracks: [t.tracks[0].id, t.tracks[1].id])
        #expect(spans(t.tracks[0]) == [[0, 10], [10, 30]])
        #expect(spans(t.tracks[1]) == [[0, 10], [10, 20]])
        #expect(spans(t.tracks[2]) == [[0, 10], [10, 20]])
        #expect(t.tracks[1].clips.last?.link == t.tracks[2].clips.last?.link)
    }

    /// Fast Cut, only the sound targeted: the main track never gets a hole (without the main track among the targets
    /// nothing changes on it). The main clip stays whole and keeps the link of the sound's left piece.
    @Test func fastCutNeverCutsTheUntargetedMainTrack() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio), a2 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        try a1.overwrite(clip(.audio, 0, 30, link: l, media: m, name: "A"))
        try a2.overwrite(clip(.audio, 0, 30, link: l, media: m, name: "A2"))
        var base = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1, a2])
        base.setEditMode(.magnetic)
        #expect(base.isFastCut)
        let r = range
        let edits: [(inout Timeline) throws -> Void] = [
            { try $0.magneticClearRange(r, tracks: [$0.tracks[1].id]) },
            { _ = try $0.magneticExtract(r, tracks: [$0.tracks[1].id]) },
        ]
        for edit in edits {
            var t = base
            try edit(&t)
            #expect(spans(t.tracks[0]) == [[0, 30]])                         // main: whole
            #expect(t.tracks[0].clips.first?.id == base.tracks[0].clips.first?.id)
            #expect(t.tracks[0].clips.first?.link == l)
            #expect(spans(t.tracks[1]) == [[0, 10], [20, 30]])
            #expect(spans(t.tracks[2]) == [[0, 10], [20, 30]])               // an untargeted partner off the main track is cut
            #expect(t.tracks[1].clips.first?.link == l && t.tracks[2].clips.first?.link == l)
            #expect(t.tracks[1].clips.last?.link == t.tracks[2].clips.last?.link && t.tracks[1].clips.last?.link != l)
        }
    }

    /// Fast Cut J-cut, only the sound targeted, range before the picture: the whole main clip lies after the range and
    /// goes with the sound's right piece (its body), not with the sliver left of the range.
    @Test func fastCutRelinksALaterMainPartnerToTheRightPiece() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 5, 15, link: l, media: m, name: "V"))
        try a1.overwrite(clip(.audio, 0, 15, link: l, media: m, name: "A"))
        var base = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1])
        base.setEditMode(.magnetic)
        let r = TimeRange(start: s(2), duration: s(2))
        let edits: [(inout Timeline) throws -> Void] = [
            { try $0.magneticClearRange(r, tracks: [$0.tracks[1].id]) },
            { _ = try $0.magneticExtract(r, tracks: [$0.tracks[1].id]) },
        ]
        for edit in edits {
            var t = base
            try edit(&t)
            let v = t.tracks[0].clips, a = t.tracks[1].clips
            #expect(v.count == 1 && a.count == 2)
            guard v.count == 1, a.count == 2 else { continue }
            #expect(v[0].id == base.tracks[0].clips[0].id && v[0].duration == s(10))   // main clip whole
            #expect(a[0].duration == s(2) && a[1].duration == s(11))
            #expect(a[0].link == l)
            #expect(a[1].link != nil && a[1].link != l && v[0].link == a[1].link)
        }
    }

    /// Normal mode, only the sound targeted: the picture partner is cut with it.
    @Test func normalModeCutsThePicturePartnerOfATargetedSound() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        try a1.overwrite(clip(.audio, 0, 30, link: l, media: m, name: "A"))
        let base = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1])
        var t = base, f = base, e = base
        try t.lift(range, tracks: [t.tracks[1].id])
        #expect(spans(t.tracks[0]) == [[0, 10], [20, 30]])
        #expect(spans(t.tracks[1]) == [[0, 10], [20, 30]])
        expectLinks(t)
        try f.magneticClearRange(range, tracks: [f.tracks[1].id])            // not Fast Cut: plain `lift`
        #expect(spans(f.tracks[0]) == [[0, 10], [20, 30]])
        _ = try e.magneticExtract(range, tracks: [e.tracks[1].id])
        #expect(spans(e.tracks[0]) == [[0, 10], [10, 20]])
        expectLinks(e)
    }

    // MARK: Transitions

    /// An unlinked clip crossfades into the partner on the untargeted track and the cut pulls the two apart: the
    /// transition goes. On a targeted track too. One whose clips still touch stays.
    @Test func liftDropsATransitionWhoseClipsNoLongerTouch() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio), a2 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        let x = clip(.audio, 5, 15, name: "X"), p = clip(.audio, 15, 30, link: l, media: m, name: "P")
        let q = clip(.audio, 30, 40, name: "Q")
        try a1.overwrite(x); try a1.overwrite(p); try a1.overwrite(q)
        a1.transitions = [Transition(kind: .constantPower, duration: s(1), outgoing: x.id, incoming: p.id),
                          Transition(kind: .constantPower, duration: s(1), outgoing: p.id, incoming: q.id)]
        let y = clip(.audio, 5, 15, name: "Y"), z = clip(.audio, 15, 30, name: "Z")
        try a2.overwrite(y); try a2.overwrite(z)
        a2.transitions = [Transition(kind: .constantPower, duration: s(1), outgoing: y.id, incoming: z.id)]
        let base = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1, a2])
        var kept = base
        kept.pruneTransitions()
        #expect(kept == base)                                                // all three are valid before the edit
        var t = base
        try t.lift(range, tracks: [t.tracks[0].id])                          // A1 untargeted: P cut to 20-30, X stays 5-15
        #expect(spans(t.tracks[1]) == [[5, 15], [20, 30], [30, 40]])
        #expect(t.tracks[1].transitions.count == 1)
        #expect(t.tracks[1].transitions.first?.incoming == q.id)
        #expect(t.tracks[2] == base.tracks[2])                               // untouched track keeps its transition
        var u = base
        try u.lift(range, tracks: [u.tracks[2].id])                          // targeted: Y 5-10, Z 20-30
        #expect(spans(u.tracks[2]) == [[5, 10], [20, 30]])
        #expect(u.tracks[2].transitions.isEmpty)
    }

    // MARK: Partner shapes

    /// Two partners of one picture, one ending and one starting inside the range (A1 0-15 and 15-35).
    @Test func partnersPartlyInsideTheRange() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        let a = clip(.audio, 0, 15, link: l, media: m, name: "A"), b = clip(.audio, 15, 35, link: l, media: m, name: "B")
        try a1.overwrite(a); try a1.overwrite(b)
        let base = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1])
        var t = base, e = base
        try t.lift(range, tracks: [t.tracks[0].id])
        #expect(spans(t.tracks[1]) == [[0, 10], [20, 35]])
        let v = t.tracks[0].clips, p = t.tracks[1].clips
        #expect(p[0].id == a.id && p[0].link == l && v[0].link == l)
        #expect(p[1].id == b.id && p[1].link == v[1].link && v[1].link != l)  // trimmed, not split: keeps its id, joins the right piece
        #expect(p[1].source.start == b.source.start + s(5))
        try e.extract(range, tracks: [e.tracks[0].id])
        #expect(spans(e.tracks[1]) == [[0, 10], [10, 25]])
        #expect(e.tracks[1].clips.map(\.source) == p.map(\.source))
        #expect(e.tracks[1].clips[1].link == e.tracks[0].clips[1].link)
    }

    /// A short partner wholly inside the range is removed, in Clear Range as in Delete Range.
    @Test func aPartnerWhollyInsideTheRangeIsRemoved() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        try a1.overwrite(clip(.audio, 12, 18, link: l, media: m, name: "short"))
        try a1.overwrite(clip(.audio, 32, 38, name: "other"))
        let base = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1])
        var t = base, e = base
        try t.lift(range, tracks: [t.tracks[0].id])
        #expect(t.tracks[1].clips.map(\.name) == ["other"])
        #expect(spans(t.tracks[1]) == [[32, 38]])
        try e.extract(range, tracks: [e.tracks[0].id])
        #expect(e.tracks[1].clips.map(\.name) == ["other"])
    }

    /// Keys of a cut partner stay on the same source times on both pieces.
    @Test func aCutPartnerKeepsItsKeysOnTheSameSourceTimes() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        var a = clip(.audio, 0, 30, link: l, media: m, name: "A")
        a.animation.volume.track = KeyframeTrack(keys: [Keyframe(time: s(5), value: 0.2), Keyframe(time: s(25), value: 0.8)])
        try a1.overwrite(a)
        var t = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1])
        func keys(_ c: Clip) -> [Time: Double] {
            Dictionary(uniqueKeysWithValues: c.animation.volume.track.keys.map { (c.source.start + $0.time, $0.value) })
        }
        let before = keys(a)
        #expect(before == [s(35): 0.2, s(55): 0.8])
        try t.lift(range, tracks: [t.tracks[0].id])
        let p = t.tracks[1].clips
        #expect(p.count == 2)
        for c in p {
            let k = keys(c)
            #expect(!k.isEmpty)
            for (time, value) in k { #expect(before[time] == value) }
        }
        #expect(p.first.map(keys)?[s(35)] == 0.2 && p.last.map(keys)?[s(55)] == 0.8)
    }
}
