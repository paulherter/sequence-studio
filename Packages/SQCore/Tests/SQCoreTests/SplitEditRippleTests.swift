import Foundation
import Testing
@testable import SQCore

/// Ripple edits next to split edits (J/L cuts): a linked clip that starts before the ripple's edit point but whose
/// partner starts after it ("straddler") must move with its partner, so the pair keeps its offset. It may limit the
/// ripple (a real collision is still reported as a clamp) but never stays behind while the partner moves.
@Suite struct SplitEditRippleTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }

    private func clip(_ kind: TrackKind, _ start: Int64, _ end: Int64, link: UUID? = nil, media: UUID = UUID(), name: String) -> Clip {
        Clip(name: name, media: media, kind: kind, source: TimeRange(start: s(30), duration: s(end - start)), start: s(start),
             link: link, mediaDuration: s(200))
    }

    /// V2: unlinked title over `title`. V1/A1: pair A (`a`) and pair B (`bv` picture, `ba` sound), linked per pair.
    private func timeline(title: (Int64, Int64), av: (Int64, Int64), aa: (Int64, Int64), bv: (Int64, Int64), ba: (Int64, Int64))
        throws -> Timeline {
        let la = UUID(), lb = UUID(), ma = UUID(), mb = UUID()
        var v1 = Track(kind: .video), v2 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(clip(.video, av.0, av.1, link: la, media: ma, name: "Av"))
        try v1.overwrite(clip(.video, bv.0, bv.1, link: lb, media: mb, name: "Bv"))
        try a1.overwrite(clip(.audio, aa.0, aa.1, link: la, media: ma, name: "Aa"))
        try a1.overwrite(clip(.audio, ba.0, ba.1, link: lb, media: mb, name: "Ba"))
        try v2.overwrite(clip(.video, title.0, title.1, name: "title"))
        return Timeline(name: "split", frameDuration: Time(1, 30), tracks: [v1, v2, a1])
    }

    private func named(_ t: Timeline, _ n: String) -> Clip { t.tracks.flatMap(\.clips).first { $0.name == n }! }

    private func expectSound(_ t: Timeline, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(t.tracks.allSatisfy { $0.isConsistent }, sourceLocation: sourceLocation)
    }

    /// J cut on B (sound 3 s before the picture), room on A1: deleting the title moves B by the full 10 s, sound included.
    @Test func rippleDeleteBeforeJCutMovesTheStraddlingSound() throws {
        var t = try timeline(title: (10, 20), av: (0, 10), aa: (0, 6), bv: (20, 30), ba: (17, 30))
        let r = try t.rippleDeleteDetailed([named(t, "title").id])
        #expect(r.closed == s(10))
        #expect(r.clamp == nil)
        #expect(named(t, "Bv").start == s(10))
        #expect(named(t, "Ba").start == s(7))
        expectSound(t)
    }

    /// Same J cut but the sound of A leaves only 7 s: B closes 7 s and stays in sync; the clamp is reported.
    @Test func rippleDeleteBeforeJCutClampsOnTheSoundTrack() throws {
        var t = try timeline(title: (10, 20), av: (0, 10), aa: (0, 10), bv: (20, 30), ba: (17, 30))
        let r = try t.rippleDeleteDetailed([named(t, "title").id])
        #expect(r.closed == s(7))
        #expect(r.clamp?.shortfall == s(3))
        #expect(named(t, "Bv").start == s(13))
        #expect(named(t, "Ba").start == s(10))
        expectSound(t)
    }

    /// L cut into B (picture 3 s before the sound): the picture straddles the edit point and limits the ripple.
    @Test func rippleDeleteNextToLCutMovesTheStraddlingPicture() throws {
        var t = try timeline(title: (5, 12), av: (0, 5), aa: (0, 5), bv: (10, 20), ba: (13, 20))
        let r = try t.rippleDeleteDetailed([named(t, "title").id])
        #expect(r.closed == s(5))
        #expect(named(t, "Bv").start == s(5))
        #expect(named(t, "Ba").start == s(8))
        expectSound(t)
    }

    /// Deleting the A pair itself (sound runs 2 s into B's picture): one amount for every track, B keeps its offset.
    @Test func rippleDeleteOfTheLCutPairKeepsTheNextPairInSync() throws {
        var t = try timeline(title: (40, 41), av: (0, 10), aa: (0, 12), bv: (10, 20), ba: (12, 20))
        try t.rippleDelete([named(t, "Av").id])
        #expect(named(t, "Bv").start == s(0))
        #expect(named(t, "Ba").start == s(2))
        expectSound(t)
    }

    /// Ripple trim (shorten the title's tail) next to the same L cut: the straddling picture follows.
    @Test func rippleTrimNextToLCutMovesTheStraddlingPicture() throws {
        var t = try timeline(title: (3, 12), av: (0, 3), aa: (0, 3), bv: (10, 20), ba: (13, 20))
        let moved = try t.rippleTrim(named(t, "title").id, edge: .tail, by: s(-7))
        #expect(named(t, "Ba").start - named(t, "Bv").start == s(3))
        #expect(named(t, "title").timeline.end == s(12) + moved)
        #expect(named(t, "Bv").start == s(10) + moved)
        expectSound(t)
    }

    /// Ripple trim before a J cut with room: the full trim applies and the sound follows.
    @Test func rippleTrimBeforeJCutMovesTheStraddlingSound() throws {
        var t = try timeline(title: (5, 20), av: (0, 5), aa: (0, 5), bv: (20, 30), ba: (17, 30))
        let moved = try t.rippleTrim(named(t, "title").id, edge: .tail, by: s(-10))
        #expect(moved == s(-10))
        #expect(named(t, "Bv").start == s(10))
        #expect(named(t, "Ba").start == s(7))
        expectSound(t)
    }

    /// Delete Range on V2 only, before a J cut: the untargeted sync-locked tracks close too and B stays in sync.
    @Test func extractBeforeJCutMovesTheStraddlingSound() throws {
        var t = try timeline(title: (10, 20), av: (0, 10), aa: (0, 6), bv: (20, 30), ba: (17, 30))
        let closed = try t.extract(TimeRange(start: s(10), duration: s(10)), tracks: [t.tracks[1].id])
        #expect(named(t, "Ba").start - named(t, "Bv").start == s(-3))
        #expect(named(t, "Bv").start == s(20) - closed)
        expectSound(t)
    }

    /// Extract on V1 only, through a linked pair whose sound is on the untargeted A1: the sound is cut with its picture,
    /// its right piece joins the picture's right piece (same new link) and both close together.
    @Test func extractThroughPairOnlyTargetingPictureKeepsSoundLinkedAndInSync() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        try a1.overwrite(clip(.audio, 0, 30, link: l, media: m, name: "A"))
        var t = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1])
        let closed = try t.extract(TimeRange(start: s(10), duration: s(10)), tracks: [t.tracks[0].id])
        #expect(closed == s(10))
        let v = t.tracks[0].clips, a = t.tracks[1].clips
        #expect(v.map(\.start) == [s(0), s(10)] && a.map(\.start) == [s(0), s(10)])
        #expect(v[0].link == a[0].link && v[1].link == a[1].link)
        #expect(v[0].link != v[1].link)
        expectSound(t)
    }

    /// The untargeted partner lies after the cut piece (an L cut): it moves with the right piece and takes its new link.
    @Test func extractGivesALaterPartnerTheLinkOfTheRightPiece() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        try a1.overwrite(clip(.audio, 22, 30, link: l, media: m, name: "A"))
        var t = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1])
        try t.extract(TimeRange(start: s(10), duration: s(10)), tracks: [t.tracks[0].id])
        let v = t.tracks[0].clips, a = t.tracks[1].clips
        #expect(a.count == 1 && a[0].start - v[1].start == s(2))
        #expect(a[0].link == v[1].link)
        #expect(v[0].link != v[1].link)
    }

    /// A cut partner's tail transition moves to its right piece.
    @Test func extractMovesThePartnersTailTransitionToTheRightPiece() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        let a = clip(.audio, 0, 30, link: l, media: m, name: "A")
        let b = clip(.audio, 30, 40, media: UUID(), name: "B")
        try a1.overwrite(a); try a1.overwrite(b)
        a1.transitions = [Transition(kind: .crossDissolve, duration: s(1), outgoing: a.id, incoming: b.id)]
        var t = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1])
        try t.extract(TimeRange(start: s(10), duration: s(10)), tracks: [t.tracks[0].id])
        let pieces = t.tracks[1].clips
        #expect(pieces.count == 3)
        #expect(t.tracks[1].transitions.first?.outgoing == pieces[1].id)
    }

    /// A sync-lock-off track with nothing cut or relinked does not ripple.
    @Test func extractLeavesASyncLockOffTrackAloneWhenNothingOnItWasCut() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio, syncLock: false)
        try v1.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        try a1.overwrite(clip(.audio, 0, 8, link: l, media: m, name: "A"))
        try a1.overwrite(clip(.audio, 25, 60, name: "M"))
        var t = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1])
        let closed = try t.extract(TimeRange(start: s(10), duration: s(10)), tracks: [t.tracks[0].id])
        #expect(closed == s(10))
        #expect(named(t, "M").start == s(25))
    }

    /// removeCuts agrees with extract when an untargeted sync-lock-off track holds a partner.
    @Test func removeCutsMatchesExtractForAnUntargetedPartner() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio, syncLock: false)
        try v1.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        try a1.overwrite(clip(.audio, 0, 30, link: l, media: m, name: "A"))
        let base = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1])
        let range = TimeRange(start: s(10), duration: s(10))
        var one = base, batch = base
        try one.extract(range, tracks: [one.tracks[0].id])
        try batch.removeCuts([range], tracks: [batch.tracks[0].id])
        #expect(batch.tracks[1].clips.map(\.start) == one.tracks[1].clips.map(\.start))
        #expect(batch.tracks[1].clips.count == 2)
        #expect(batch.tracks[1].clips[0].link != batch.tracks[1].clips[1].link)
        #expect(batch.tracks[0].clips[1].link == batch.tracks[1].clips[1].link)
    }

    /// A later partner on a targeted track takes the right piece's new link too.
    @Test func extractRelinksALaterPartnerOnATargetedTrack() throws {
        let l = UUID(), m = UUID()
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(clip(.video, 0, 30, link: l, media: m, name: "V"))
        try a1.overwrite(clip(.audio, 22, 52, link: l, media: m, name: "A"))
        var t = Timeline(name: "x", frameDuration: Time(1, 30), tracks: [v1, a1])
        try t.extract(TimeRange(start: s(10), duration: s(10)), tracks: [t.tracks[0].id, t.tracks[1].id])
        #expect(t.tracks[1].clips[0].link == t.tracks[0].clips[1].link)
        #expect(t.tracks[0].clips[0].link != t.tracks[0].clips[1].link)
    }
}
