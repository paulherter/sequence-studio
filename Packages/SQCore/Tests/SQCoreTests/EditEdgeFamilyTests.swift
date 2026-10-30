import Foundation
import Testing
@testable import SQCore

/// One test per bug family from docs/FILMCRAFT-PRS.md "Watch for" and docs/FILMCRAFT-ISSUES.md (#526-530, #548, #855,
/// #911, #912, #917, #918): linked partners share one delta, reversed clips use the opposite handle, transitions and
/// fades follow, one gesture is one undo step, locked tracks refuse everything including linked partners.
@Suite struct EditEdgeFamilyTests {
    static let fd = Time(1, 30)
    /// Whole seconds are whole frames at 30 fps.
    static func s(_ n: Int64) -> Time { Time(n, 1) }

    /// `src` = used source start, `len` = timeline length, `md` = media duration (handles = src and md - src - len).
    static func clip(_ kind: TrackKind = .video, at start: Int64, len: Int64, src: Int64 = 5, md: Int64 = 40,
                     link: UUID? = nil, reversed: Bool = false, media: UUID = UUID()) -> Clip {
        var c = Clip(name: "c", media: media, kind: kind, source: TimeRange(start: s(src), duration: s(len)),
                     start: s(start), link: link, mediaDuration: s(md))
        c.reversed = reversed
        return c
    }

    static func track(_ clips: [Clip], kind: TrackKind = .video, locked: Bool = false) -> Track {
        var t = Track(kind: kind)
        for c in clips { try! t.overwrite(c) }
        t.isLocked = locked
        return t
    }

    static func timeline(_ tracks: [Track]) -> Timeline { Timeline(name: "t", frameDuration: fd, tracks: tracks) }

    // MARK: (1) linked partners share one clamped delta

    @Test func slideClampsToTheTightestLinkedPartner() throws {
        let l = UUID()
        // Video neighbors have long handles; the sound neighbors have two seconds of head handle and none of tail room.
        let v = [Self.clip(at: 0, len: 10), Self.clip(at: 10, len: 10, link: l), Self.clip(at: 20, len: 10)]
        let a = [Self.clip(.audio, at: 0, len: 10, src: 0, md: 10), Self.clip(.audio, at: 10, len: 10, link: l),
                 Self.clip(.audio, at: 20, len: 10, src: 2, md: 40)]
        var tl = Self.timeline([Self.track(v), Self.track(a, kind: .audio)])
        let moved = try tl.slide(v[1].id, by: Self.s(-6))
        #expect(moved == Self.s(-2))
        #expect(tl.find(v[1].id)!.clip.start == Self.s(8) && tl.find(a[1].id)!.clip.start == Self.s(8))
        var up = Self.timeline([Self.track(v), Self.track(a, kind: .audio)])
        // Sound previous clip has no tail room: nothing moves, picture and sound stay together.
        #expect(try up.slide(v[1].id, by: Self.s(5)) == .zero)
        #expect(up.find(v[1].id)!.clip.start == up.find(a[1].id)!.clip.start)
    }

    @Test func rollClampsToTheTightestLinkedPartner() throws {
        let l = UUID(), k = UUID()
        let v = [Self.clip(at: 0, len: 10, link: l), Self.clip(at: 10, len: 10, link: k)]
        let a = [Self.clip(.audio, at: 0, len: 10, src: 5, md: 17, link: l), Self.clip(.audio, at: 10, len: 10, link: k)]
        var tl = Self.timeline([Self.track(v), Self.track(a, kind: .audio)])
        #expect(try tl.roll(v[0].id, by: Self.s(5)) == Self.s(2))     // sound left clip has 2 s of tail room
        #expect(tl.find(v[0].id)!.clip.timeline.end == Self.s(12))
        #expect(tl.find(a[0].id)!.clip.timeline.end == Self.s(12))
        #expect(tl.find(v[1].id)!.clip.start == Self.s(12) && tl.find(a[1].id)!.clip.start == Self.s(12))
    }

    @Test func slipClampsToTheTightestLinkedPartner() throws {
        let l = UUID()
        let v = Self.clip(at: 0, len: 10, src: 5, md: 40, link: l)
        let a = Self.clip(.audio, at: 0, len: 10, src: 5, md: 17, link: l)       // 2 s after, 5 s before
        var tl = Self.timeline([Self.track([v]), Self.track([a], kind: .audio)])
        #expect(try tl.slip(v.id, by: Self.s(4)) == Self.s(2))
        #expect(tl.find(v.id)!.clip.source.start == Self.s(7) && tl.find(a.id)!.clip.source.start == Self.s(7))
        #expect(try tl.slip(v.id, by: Self.s(-20)) == Self.s(-7))      // back to the media start (2 + 5)
        #expect(tl.find(v.id)!.clip.source.start == .zero && tl.find(a.id)!.clip.source.start == .zero)
    }

    @Test func rateStretchGivesLinkedPartnersOneSpeedAndLength() throws {
        let l = UUID()
        let v = Self.clip(at: 0, len: 10, src: 5, md: 40, link: l)
        let a = Self.clip(.audio, at: 0, len: 10, src: 5, md: 40, link: l)
        var tl = Self.timeline([Self.track([v]), Self.track([a], kind: .audio)])
        let moved = try tl.rateStretch(v.id, edge: .tail, by: Self.s(5))
        #expect(moved == Self.s(5))
        let cv = tl.find(v.id)!.clip, ca = tl.find(a.id)!.clip
        #expect(cv.speed == ca.speed)
        #expect(cv.timeline == ca.timeline)
        #expect(cv.source == ca.source)
    }

    @Test func rateStretchHeadOfLinkedPairKeepsThemInSync() throws {
        let l = UUID()
        let v = Self.clip(at: 10, len: 10, src: 5, md: 40, link: l)
        let a = Self.clip(.audio, at: 10, len: 10, src: 5, md: 40, link: l)
        var tl = Self.timeline([Self.track([v]), Self.track([a], kind: .audio)])
        _ = try tl.rateStretch(a.id, edge: .head, by: Self.s(-4))       // from the sound clip: picture follows
        let cv = tl.find(v.id)!.clip, ca = tl.find(a.id)!.clip
        #expect(cv.speed == ca.speed && cv.timeline == ca.timeline)
        #expect(cv.start == Self.s(6))
    }

    @Test func nudgeClampsAtZeroForTheWholeLinkedGroup() throws {
        let l = UUID()
        let v = Self.clip(at: 5, len: 10, link: l)
        let a = Self.clip(.audio, at: 2, len: 10, link: l)               // J cut: sound leads by 3 s
        var tl = Self.timeline([Self.track([v]), Self.track([a], kind: .audio)])
        #expect(try tl.nudge([v.id], by: Self.s(-10)) == Self.s(-2))
        #expect(tl.find(v.id)!.clip.start == Self.s(3) && tl.find(a.id)!.clip.start == .zero)
        // The sound is already at zero: the picture cannot go further either, nothing moves alone.
        #expect(try tl.move(v.id, to: Self.s(-4)) == .zero)
        #expect(tl.find(v.id)!.clip.start == Self.s(3) && tl.find(a.id)!.clip.start == .zero)
    }

    @Test func linkedTrimExtendUsesOneDelta() throws {
        let l = UUID()
        let v = Self.clip(at: 10, len: 10, src: 5, md: 40, link: l)
        let a = Self.clip(.audio, at: 10, len: 10, src: 5, md: 18, link: l)      // 3 s of tail room
        var tl = Self.timeline([Self.track([v]), Self.track([a], kind: .audio)])
        #expect(try tl.trim(v.id, edge: .tail, by: Self.s(8)) == Self.s(3))
        #expect(tl.find(v.id)!.clip.duration == tl.find(a.id)!.clip.duration)
        #expect(try tl.rippleTrim(v.id, edge: .tail, by: Self.s(8)) == .zero)   // no room left on either
        #expect(tl.find(v.id)!.clip.duration == tl.find(a.id)!.clip.duration)
    }

    // MARK: (2) reversed clips consume the opposite end

    /// Source 3...13 of 20 s: forward head handle 3 / tail room 7, reversed head handle 7 / tail room 3.
    static func reversedClip(at start: Int64 = 10) -> Clip { clip(at: start, len: 10, src: 3, md: 20, reversed: true) }

    @Test func reversedTrimUsesTheOppositeHandle() throws {
        let c = Self.reversedClip()
        var tl = Self.timeline([Self.track([c])])
        #expect(try tl.trim(c.id, edge: .head, by: Self.s(-9)) == Self.s(-7))      // head plays the source end: 7 s left
        #expect(tl.find(c.id)!.clip.source.end == Self.s(20))
        var t2 = Self.timeline([Self.track([c])])
        #expect(try t2.trim(c.id, edge: .tail, by: Self.s(9)) == Self.s(3))       // tail plays the source start: 3 s left
        #expect(t2.find(c.id)!.clip.source.start == .zero)
    }

    @Test func reversedRollUsesTheOppositeHandleOnBothSides() throws {
        let left = Self.reversedClip(at: 10)
        let right = Self.clip(at: 20, len: 10, src: 5, md: 40)
        var tl = Self.timeline([Self.track([left, right])])
        #expect(try tl.roll(left.id, by: Self.s(6)) == Self.s(3))                 // reversed left: tail room 3
        #expect(tl.find(left.id)!.clip.source.start == .zero)

        let l2 = Self.clip(at: 10, len: 10, src: 5, md: 40), r2 = Self.reversedClip(at: 20)
        var t2 = Self.timeline([Self.track([l2, r2])])
        #expect(try t2.roll(l2.id, by: Self.s(-9)) == Self.s(-7))                 // reversed right: head handle 7
        #expect(t2.find(r2.id)!.clip.source.end == Self.s(20))
    }

    @Test func reversedSlipFollowsThePointerAndStopsAtMediaEnds() throws {
        let c = Self.reversedClip(at: 0)
        var tl = Self.timeline([Self.track([c])])
        #expect(try tl.slip(c.id, by: Self.s(5)) == Self.s(3))                    // earlier source: 3 s
        #expect(tl.find(c.id)!.clip.source.start == .zero)
        #expect(try tl.slip(c.id, by: Self.s(-20)) == Self.s(-10))                // later source: 3 back + 7 more
        #expect(tl.find(c.id)!.clip.source.end == Self.s(20))
    }

    @Test func reversedExtendEditAndSlideUseTheOppositeHandle() throws {
        let c = Self.reversedClip(at: 10)
        var tl = Self.timeline([Self.track([c])])
        #expect(try tl.extendEdit(c.id, edge: .tail, to: Self.s(40)) == Self.s(3))
        #expect(try tl.extendEdit(c.id, edge: .head, to: .zero) == Self.s(-7))

        // Slide with reversed neighbors (#548): previous tail room 3, next head handle 7.
        let prev = Self.reversedClip(at: 0), mid = Self.clip(at: 10, len: 10, src: 5, md: 40)
        let next = Self.clip(at: 20, len: 10, src: 3, md: 20, reversed: true)
        var s = Self.timeline([Self.track([prev, mid, next])])
        #expect(try s.slide(mid.id, by: Self.s(8)) == Self.s(3))
        #expect(s.find(prev.id)!.clip.source.start == .zero)
        var s2 = Self.timeline([Self.track([prev, mid, next])])
        #expect(try s2.slide(mid.id, by: Self.s(-8)) == Self.s(-7))
        #expect(s2.find(next.id)!.clip.source.end == Self.s(20))
    }

    @Test func reversedPairStaysInSyncWithItsPartner() throws {
        let l = UUID()
        let v = Self.clip(at: 10, len: 10, src: 3, md: 20, link: l, reversed: true)
        let a = Self.clip(.audio, at: 10, len: 10, src: 3, md: 20, link: l, reversed: true)
        var tl = Self.timeline([Self.track([v]), Self.track([a], kind: .audio)])
        #expect(try tl.trim(a.id, edge: .head, by: Self.s(-9)) == Self.s(-7))
        #expect(tl.find(v.id)!.clip.timeline == tl.find(a.id)!.clip.timeline)
        #expect(tl.find(v.id)!.clip.source == tl.find(a.id)!.clip.source)
    }

    // MARK: (3) transitions and fades follow the clip

    private func transitionSetup() throws -> (Timeline, [Clip]) {
        let a = Self.clip(at: 0, len: 10), b = Self.clip(at: 10, len: 10), c = Self.clip(at: 20, len: 10)
        var tl = Self.timeline([Self.track([a, b, c])])
        let id = tl.tracks[0].id
        _ = try tl.addTransition(point: .cut(outgoing: a.id, incoming: b.id), kind: .crossDissolve, track: id, duration: Time(10, 30))
        _ = try tl.addTransition(point: .cut(outgoing: b.id, incoming: c.id), kind: .crossDissolve, track: id, duration: Time(10, 30))
        _ = try tl.addTransition(point: .head(a.id), kind: .crossDissolve, track: id, duration: Time(6, 30))
        return (tl, [a, b, c])
    }

    private func transitionProblems(_ tl: Timeline) -> [String] {
        // `Project.edit` prunes after every edit (transitions whose cut is gone or whose handles hold no frame).
        var out: [String] = []
        for var t in tl.tracks {
            t.pruneTransitions(frameDuration: tl.frameDuration)
            for x in t.transitions {
                let ids = [x.outgoing, x.incoming].compactMap { $0 }
                if ids.contains(where: { t.clip($0) == nil }) { out.append("dangling \(x.id)") }
                if let o = x.outgoing, let i = x.incoming, let co = t.clip(o), let ci = t.clip(i), co.timeline.end != ci.start {
                    out.append("cut transition across a gap")
                }
            }
        }
        return out
    }

    @Test func transitionsStayAttachedThroughTrimRollSlideAndSpeed() throws {
        let (base, c) = try transitionSetup()
        #expect(base.tracks[0].transitions.count == 3)
        // Verbs that open a gap beside the clip legitimately lose the transition across it (pruned by Project.edit).
        let gapMakers: Set<String> = ["trim head", "speed", "rate stretch"]
        let verbs: [(String, (inout Timeline) throws -> Void)] = [
            ("trim head", { _ = try $0.trim(c[1].id, edge: .head, by: Self.s(2)) }),
            ("rollback", { _ = try $0.roll(c[0].id, by: Self.s(-3)) }),
            ("roll", { _ = try $0.roll(c[1].id, by: Self.s(3)) }),
            ("slide", { _ = try $0.slide(c[1].id, by: Self.s(2)) }),
            ("slip", { _ = try $0.slip(c[1].id, by: Self.s(2)) }),
            ("ripple trim tail", { _ = try $0.rippleTrim(c[0].id, edge: .tail, by: Self.s(-3)) }),
            ("ripple trim head", { _ = try $0.rippleTrim(c[1].id, edge: .head, by: Self.s(2)) }),
            ("speed", { _ = try $0.apply(SpeedChange(speed: ClipSpeed(percent: 200)), to: c[1].id) }),
            ("speed ripple", { _ = try $0.apply(SpeedChange(speed: ClipSpeed(percent: 50), ripple: true), to: c[1].id) }),
            ("reverse", { _ = try $0.apply(SpeedChange(reversed: true), to: c[1].id) }),
            ("rate stretch", { _ = try $0.rateStretch(c[1].id, edge: .tail, by: Self.s(-4)) }),
        ]
        for (name, edit) in verbs {
            var tl = base
            try edit(&tl)
            var pruned = tl.tracks[0]
            pruned.pruneTransitions(frameDuration: tl.frameDuration)
            if !gapMakers.contains(name) { #expect(pruned.transitions.count == 3, "\(name): transition lost") }
            #expect(transitionProblems(tl).isEmpty, "\(name): \(transitionProblems(tl))")
        }
    }

    @Test func movedClipsLeaveNoDanglingTransitions() throws {
        let (base, c) = try transitionSetup()
        var m = base
        try m.move(c[1].id, to: Self.s(50))
        #expect(transitionProblems(m).isEmpty)
        var r = base
        try r.rippleDelete([c[1].id])
        #expect(transitionProblems(r).isEmpty)
        var i = base
        try i.moveInsert(c[0].id, to: Self.s(25))
        #expect(transitionProblems(i).isEmpty)
        var n = base
        _ = try n.nudge([c[2].id], by: Self.s(5))
        #expect(transitionProblems(n).isEmpty)
        // The A|B transition is still there after only C moved.
        #expect(n.tracks[0].transitions.contains { $0.outgoing == c[0].id && $0.incoming == c[1].id })
    }

    @Test func audioFadeOutFollowsTheTailThroughSpeedAndTrim() throws {
        var a = Self.clip(.audio, at: 0, len: 10)
        a.setAudioFadeOut(Time(10, 30), frameDuration: Self.fd)
        let base = Self.timeline([Self.track([a], kind: .audio)])
        #expect(base.find(a.id)!.clip.audioFadeOut == Time(10, 30))
        for ripple in [false, true] {
            var tl = base
            _ = try tl.apply(SpeedChange(speed: ClipSpeed(percent: 200), ripple: ripple), to: a.id)
            let c = tl.find(a.id)!.clip
            #expect(c.duration == Self.s(5))
            #expect(c.audioFadeOut > .zero, "speed ripple \(ripple): fade lost")
            #expect(c.animation.volume.track.keys.map(\.time).max() == c.duration, "fade key left at the old end")
        }
        // A tail trim and its reversal bring the fade back (handles are not data loss).
        var tr = base
        _ = try tr.rippleTrim(a.id, edge: .tail, by: Self.s(-3))
        _ = try tr.rippleTrim(a.id, edge: .tail, by: Self.s(3))
        #expect(tr.find(a.id)!.clip.audioFadeOut == Time(10, 30))
    }

    // MARK: (4) one gesture, one undo step

    @Test func aGestureOfManyCommitsIsOneUndoStep() throws {
        let l = UUID()
        let v = Self.clip(at: 10, len: 10, link: l), a = Self.clip(.audio, at: 10, len: 10, link: l)
        let start = Self.timeline([Self.track([v]), Self.track([a], kind: .audio)])
        var h = History(start, limit: 50)
        for _ in 0..<12 {
            h.commit("Trim", coalescing: "trim:\(v.id)") { _ = try? $0.trim(v.id, edge: .tail, by: Self.fd) }
        }
        #expect(h.undoNames.count == 1)
        #expect(h.current.find(a.id)!.clip.duration == Self.s(10) + Self.fd * 12)
        h.endCoalescing()
        let undone = h.undo()
        #expect(undone)
        #expect(h.current == start)
        #expect(!h.canUndo)
    }

    @Test func linkedVerbsAreOneStepEach() throws {
        let l = UUID(), k = UUID()
        let v = [Self.clip(at: 0, len: 10, link: l), Self.clip(at: 10, len: 10, link: k)]
        let a = [Self.clip(.audio, at: 0, len: 10, link: l), Self.clip(.audio, at: 10, len: 10, link: k)]
        let start = Self.timeline([Self.track(v), Self.track(a, kind: .audio)])
        var h = History(start, limit: 50)
        try h.commit("Roll") { _ = try $0.roll(v[0].id, by: Self.s(2)) }
        try h.commit("Slip") { _ = try $0.slip(v[1].id, by: Self.s(1)) }
        try h.commit("Ripple delete") { try $0.rippleDelete([v[0].id]) }
        #expect(h.undoNames == ["Roll", "Slip", "Ripple delete"])
        let u1 = h.undo(), u2 = h.undo(), u3 = h.undo()
        #expect(u1 && u2 && u3)
        #expect(h.current == start)
    }

    // MARK: (5) locked tracks refuse everything, including linked partners

    @Test func lockedPartnerRefusesEveryEditVerb() throws {
        let l = UUID(), k = UUID()
        let v = [Self.clip(at: 0, len: 10, link: l), Self.clip(at: 10, len: 10, link: k), Self.clip(at: 20, len: 10)]
        let a = [Self.clip(.audio, at: 0, len: 10, link: l), Self.clip(.audio, at: 10, len: 10, link: k),
                 Self.clip(.audio, at: 20, len: 10)]
        let vt = Self.track(v), at = Self.track(a, kind: .audio, locked: true)
        let base = Self.timeline([vt, at])
        let (vid, aid) = (vt.id, at.id)
        let fd = Self.fd
        let verbs: [(String, (inout Timeline) throws -> Void)] = [
            ("trim head", { _ = try $0.trim(v[1].id, edge: .head, by: Self.s(2)) }),
            ("trim tail", { _ = try $0.trim(v[1].id, edge: .tail, by: Self.s(-2)) }),
            ("ripple trim", { _ = try $0.rippleTrim(v[1].id, edge: .tail, by: Self.s(-2)) }),
            ("roll", { _ = try $0.roll(v[0].id, by: Self.s(2)) }),
            ("slip", { _ = try $0.slip(v[1].id, by: Self.s(1)) }),
            ("slide", { _ = try $0.slide(v[1].id, by: Self.s(2)) }),
            ("move", { _ = try $0.move(v[1].id, to: Self.s(40)) }),
            ("move insert", { try $0.moveInsert(v[1].id, to: Self.s(40)) }),
            ("nudge", { _ = try $0.nudge([v[1].id], by: Self.s(3)) }),
            ("ripple delete", { _ = try $0.rippleDelete([v[0].id]) }),
            ("rate stretch", { _ = try $0.rateStretch(v[1].id, edge: .tail, by: Self.s(-3)) }),
            ("speed", { _ = try $0.apply(SpeedChange(speed: ClipSpeed(percent: 50)), to: v[1].id) }),
            ("duration", { _ = try $0.apply(SpeedChange(duration: Self.s(5)), to: v[1].id) }),
            ("reverse", { _ = try $0.apply(SpeedChange(reversed: true), to: v[1].id) }),
            ("extend edit", { _ = try $0.extendEdit(v[0].id, edge: .tail, to: Self.s(12)) }),
            ("split", { _ = try $0.addEdit(at: Self.s(5), selection: [v[0].id]) }),
            ("split edit", { _ = try $0.splitEdit(cut: Self.s(10), side: .audio, to: Self.s(12)) }),
            ("trim to playhead", { _ = try $0.trimToPlayhead(.tail, at: Self.s(7), tracks: [vid], mode: .plain) }),
            ("ripple trim to playhead", { _ = try $0.rippleTrimToPlayhead(.head, at: Self.s(3), tracks: [aid]) }),
            ("transition", { _ = try $0.addTransition(point: .cut(outgoing: a[0].id, incoming: a[1].id), kind: .constantPower, track: aid, duration: Time(6, 30)) }),
            ("lift", { try $0.lift(TimeRange(start: Self.s(2), end: Self.s(6)), tracks: [aid]) }),
            ("extract", { _ = try $0.extract(TimeRange(start: Self.s(2), end: Self.s(6)), tracks: [aid]) }),
            ("unlink", { try $0.unlink([v[0].id]) }),
        ]
        _ = fd
        for (name, edit) in verbs {
            var tl = base
            do { try edit(&tl) } catch {}
            // Unlink only clears an orphaned link id on the locked partner (bookkeeping, no edit of its content).
            if name != "unlink" { #expect(tl.tracks[1] == base.tracks[1], "\(name): the locked track changed") }
            // Whatever a verb does to the unlocked track, a clip linked to a locked partner must not move alone.
            for (i, c) in v.prefix(2).enumerated() where name != "split" {   // the razor skips the locked track by design
                let p = tl.find(c.id)?.clip, q = tl.find(a[i].id)?.clip
                #expect(p?.timeline == q?.timeline && p?.source == q?.source, "\(name): linked pair \(i) out of sync")
            }
        }
    }

    @Test func lockedTrackSkippedOnWholeSequenceTargets() throws {
        let v = Self.clip(at: 0, len: 10), a = Self.clip(.audio, at: 0, len: 10)
        let vt = Self.track([v]), at = Self.track([a], kind: .audio, locked: true)
        var tl = Self.timeline([vt, at])
        _ = try tl.addEdit(at: Self.s(5), tracks: nil)
        #expect(tl.tracks[0].clips.count == 2)
        #expect(tl.tracks[1].clips.count == 1)
        var named = tl
        #expect(throws: EditError.trackLocked) { _ = try named.addEdit(at: Self.s(2), tracks: [at.id]) }
    }

    // MARK: (6) gap select + Delete, Ripple Delete Head

    @Test func deletingASelectedGapClosesItAcrossSyncLockedTracks() throws {
        let v = [Self.clip(at: 0, len: 5), Self.clip(at: 10, len: 5)]
        let a = [Self.clip(.audio, at: 0, len: 5), Self.clip(.audio, at: 10, len: 5)]
        var tl = Self.timeline([Self.track(v), Self.track(a, kind: .audio)])
        let vid = tl.tracks[0].id
        let gap = try #require(tl.gap(on: vid, at: Self.s(7)))
        #expect(gap == TimeRange(start: Self.s(5), end: Self.s(10)))
        var h = History(tl, limit: 10)
        try h.commit("Delete gap") { try $0.closeGap(on: vid, at: Self.s(7)) }
        #expect(h.current.find(v[1].id)!.clip.start == Self.s(5))
        #expect(h.current.find(a[1].id)!.clip.start == Self.s(5))
        #expect(h.undoNames.count == 1)
        // Inside a clip there is no gap; a locked track refuses.
        #expect(tl.gap(on: vid, at: Self.s(2)) == nil)
        tl.tracks[0].isLocked = true
        #expect(throws: EditError.self) { try tl.closeGap(on: vid, at: Self.s(7)) }
        #expect(tl.find(v[1].id)!.clip.start == Self.s(10))
    }

    @Test func rippleDeleteHeadMovesLinkedPairByOneDelta() throws {
        let l = UUID()
        let v = [Self.clip(at: 10, len: 10, link: l), Self.clip(at: 20, len: 10)]
        let a = [Self.clip(.audio, at: 10, len: 10, link: l), Self.clip(.audio, at: 20, len: 10)]
        var tl = Self.timeline([Self.track(v), Self.track(a, kind: .audio)])
        // Ripple Delete Head: remove the part from the clip start to the playhead, later clips close up by that amount.
        let moved = try tl.rippleTrimToPlayhead(.head, at: Self.s(14), tracks: [tl.tracks[0].id])
        #expect(moved == Self.s(4))
        let cv = tl.find(v[0].id)!.clip, ca = tl.find(a[0].id)!.clip
        #expect(cv.timeline == ca.timeline && cv.timeline.duration == Self.s(6))
        #expect(cv.source.start == Self.s(9))
        #expect(tl.find(v[1].id)!.clip.start == Self.s(16) && tl.find(a[1].id)!.clip.start == Self.s(16))
    }
}
