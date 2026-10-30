import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }

/// Clip of `frames` frames of source from source frame `from`, media `media` frames long.
private func clip(_ name: String = "c", start: Int64, from: Int64 = 30, frames: Int64 = 60, media: Int64 = 300,
                  kind: TrackKind = .video, speed: ClipSpeed = .normal, reversed: Bool = false, link: UUID? = nil) -> Clip {
    Clip(name: name, media: UUID(), kind: kind, source: TimeRange(start: f(from), duration: f(frames)), start: f(start),
         link: link, mediaDuration: f(media), speed: speed, reversed: reversed)
}

/// One track with A at 0..60 and B at 60..120, both with 30 frames of head handle and lots of tail.
private func pair(kind: TrackKind = .video, a: Clip? = nil, b: Clip? = nil) throws -> (Timeline, Clip, Clip) {
    let ca = a ?? clip("A", start: 0, kind: kind), cb = b ?? clip("B", start: 60, kind: kind)
    var t = Track(kind: kind)
    try t.overwrite(ca); try t.overwrite(cb)
    return (Timeline(name: "t", frameDuration: fd, tracks: [t]), ca, cb)
}

@Suite struct TransitionModelTests {
    @Test func kindsBelongToATrackKind() {
        #expect(TransitionKind.crossDissolve.trackKind == .video && TransitionKind.dipToBlack.trackKind == .video
                && TransitionKind.dipToWhite.trackKind == .video)
        #expect(TransitionKind.constantPower.trackKind == .audio && TransitionKind.constantGain.trackKind == .audio)
        #expect(TransitionKind.defaultKind(for: .video) == .crossDissolve && TransitionKind.defaultKind(for: .audio) == .constantPower)
    }

    @Test func centredSpanStraddlesTheCut() throws {
        var (t, a, b) = try pair()
        let id = try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20))
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first)
        #expect(r.id == id && r.cut == f(60))
        #expect(r.span == TimeRange(start: f(50), duration: f(20)))
        #expect(r.before == f(10) && r.after == f(10) && !r.isClamped)
    }

    @Test func oddDurationGivesTheExtraFrameAfterTheCut() throws {
        var (t, a, b) = try pair()
        try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(15))
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first)
        #expect(r.before == f(7) && r.after == f(8) && r.span.start == f(53))
    }

    @Test func alignments() throws {
        var (t, a, b) = try pair()
        let tr = t.tracks[0].id
        let id = try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(20), alignment: .startAtCut)
        #expect(t.resolvedTransitions(on: tr)[0].span == TimeRange(start: f(60), duration: f(20)))
        try t.setTransition(id, alignment: .endAtCut)
        #expect(t.resolvedTransitions(on: tr)[0].span == TimeRange(start: f(40), duration: f(20)))
        try t.setTransition(id, alignment: .custom, customBefore: f(5))
        let r = t.resolvedTransitions(on: tr)[0]
        #expect(r.span == TimeRange(start: f(55), duration: f(20)) && r.before == f(5) && r.after == f(15))
        // a custom offset never leaves the cut: before is clamped to the duration
        try t.setTransition(id, alignment: .custom, customBefore: f(500))
        #expect(t.resolvedTransitions(on: tr)[0].before == f(20))
    }

    @Test func handlesLimitTheDuration() throws {
        // B starts at source frame 5: only 5 frames of head handle, so a centered transition holds at most 11 frames
        // (before = 5 is the largest the incoming handle allows).
        var (t, a, b) = try pair(b: clip("B", start: 60, from: 5))
        let tr = t.tracks[0].id
        try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(30))
        let r = t.resolvedTransitions(on: tr)[0]
        #expect(!r.isClamped)       // the stored duration was fitted when it was applied
        #expect(r.before <= f(5) && r.after >= r.before && r.span.duration == f(11))
        #expect(r.span == TimeRange(start: f(55), duration: f(11)))
    }

    @Test func noHandlesHoldsEdgeFramesForVideoAndRefusesAudio() throws {
        // A uses the end of its media and B the start: no media beyond either side of the cut. Video (Premiere parity
        // fix 8): applied at full length with both edge frames held, every alignment. Audio: still refused.
        var (t, a, b) = try pair(a: clip("A", start: 0, from: 240, frames: 60, media: 300), b: clip("B", start: 60, from: 0))
        let tr = t.tracks[0].id
        for al in [TransitionAlignment.center, .startAtCut, .endAtCut] {
            try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(20), alignment: al)
            let r = try #require(t.resolvedTransitions(on: tr).first)
            #expect(r.span.duration == f(20) && r.heldFrames == 20 && r.alignment == al)
        }
        #expect(t.tracks[0].transitions.count == 1)
        var (u, c, d) = try pair(kind: .audio, a: clip("A", start: 0, from: 240, frames: 60, media: 300, kind: .audio),
                                 b: clip("B", start: 60, from: 0, kind: .audio))
        #expect(throws: EditError.insufficientMedia) {
            try u.addTransition(kind: .constantPower, track: u.tracks[0].id, outgoing: c.id, incoming: d.id, duration: f(20))
        }
    }

    @Test func startAtCutOnlyNeedsTheOutgoingTail() throws {
        var (t, a, b) = try pair(a: clip("A", start: 0, from: 30, frames: 60, media: 300), b: clip("B", start: 60, from: 0))
        try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20), alignment: .startAtCut)
        #expect(t.resolvedTransitions(on: t.tracks[0].id)[0].span.duration == f(20))
    }

    @Test func handlesRespectSpeedAndReverse() throws {
        // A plays 200 %: its 60 timeline frames are 120 source frames (source 0..120), media 150 -> 30 source frames
        // = 15 timeline frames of tail handle.
        let fast = clip("A", start: 0, from: 0, frames: 120, media: 150, speed: ClipSpeed(percent: 200))
        var (t, a, b) = try pair(a: fast)
        #expect(a.timeline.duration == f(60))
        try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(60), alignment: .startAtCut)
        #expect(t.resolvedTransitions(on: t.tracks[0].id)[0].span.duration == f(15))
        // Reversed A: the tail plays toward the start of its source, so the handle is the source before source.start.
        let rev = clip("A", start: 0, from: 12, frames: 60, media: 300, reversed: true)
        var (t2, a2, b2) = try pair(a: rev)
        try t2.addTransition(kind: .crossDissolve, track: t2.tracks[0].id, outgoing: a2.id, incoming: b2.id, duration: f(60), alignment: .startAtCut)
        #expect(t2.resolvedTransitions(on: t2.tracks[0].id)[0].span.duration == f(12))
    }

    @Test func singleSidedTransitions() throws {
        var (t, a, _) = try pair()
        let tr = t.tracks[0].id
        try t.addTransition(kind: .dipToBlack, track: tr, outgoing: nil, incoming: a.id, duration: f(12))
        try t.addTransition(kind: .dipToBlack, track: tr, outgoing: a.id, incoming: nil, duration: f(200))   // longer than the clip
        let rs = t.resolvedTransitions(on: tr)
        let head = try #require(rs.first { $0.outgoing == nil }), tail = try #require(rs.first { $0.incoming == nil })
        #expect(head.span == TimeRange(start: f(0), duration: f(12)))
        #expect(tail.span == TimeRange(start: f(12), duration: f(48)))   // the clip also holds the 12-frame head fade
    }

    @Test func secondApplyReplacesInsteadOfStacking() throws {
        var (t, a, b) = try pair()
        let tr = t.tracks[0].id
        let first = try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(20))
        let second = try t.addTransition(kind: .dipToBlack, track: tr, outgoing: a.id, incoming: b.id, duration: f(10))
        #expect(t.tracks[0].transitions.count == 1 && second != first)
        #expect(t.tracks[0].transitions[0].kind == .dipToBlack)
    }

    @Test func oneTransitionPerClipEdge() throws {
        var (t, a, b) = try pair()
        let tr = t.tracks[0].id
        try t.addTransition(kind: .dipToBlack, track: tr, outgoing: a.id, incoming: nil, duration: f(10))   // tail of A
        try t.addTransition(kind: .dipToBlack, track: tr, outgoing: nil, incoming: b.id, duration: f(10))   // head of B
        try t.addTransition(kind: .dipToBlack, track: tr, outgoing: nil, incoming: a.id, duration: f(10))   // head of A: elsewhere
        #expect(t.tracks[0].transitions.count == 3)
        try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(10))
        // the cut replaced the tail of A and the head of B; the head of A stays
        #expect(t.tracks[0].transitions.count == 2)
        #expect(t.tracks[0].transitions.contains { $0.outgoing == nil && $0.incoming == a.id })
        #expect(t.tracks[0].transitions.contains { $0.outgoing == a.id && $0.incoming == b.id })
        try t.addTransition(kind: .dipToWhite, track: tr, outgoing: a.id, incoming: nil, duration: f(10))   // tail of A replaces the cut
        #expect(!t.tracks[0].transitions.contains { $0.incoming == b.id })
    }

    @Test func refusals() throws {
        var (t, a, b) = try pair()
        let tr = t.tracks[0].id
        #expect(throws: EditError.wrongTrackKind) {
            try t.addTransition(kind: .constantPower, track: tr, outgoing: a.id, incoming: b.id, duration: f(10))
        }
        var gap = try pair(b: clip("B", start: 70))
        #expect(throws: EditError.notACut) {
            try gap.0.addTransition(kind: .crossDissolve, track: gap.0.tracks[0].id, outgoing: gap.1.id, incoming: gap.2.id, duration: f(10))
        }
        t.tracks[0].isLocked = true
        #expect(throws: EditError.trackLocked) {
            try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(10))
        }
        #expect(throws: EditError.clipNotFound) {
            try t.addTransition(kind: .crossDissolve, track: UUID(), outgoing: a.id, incoming: b.id, duration: f(10))
        }
    }

    @Test func durationIsSnappedToWholeFrames() throws {
        var (t, a, b) = try pair()
        try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: Time(41, 60))   // 20.5 frames
        #expect(t.tracks[0].transitions[0].duration == f(20))
        let id = t.tracks[0].transitions[0].id
        try t.setTransition(id, duration: f(0))
        #expect(t.tracks[0].transitions[0].duration == f(1))
    }

    @Test func setDurationClampsToAvailableMedia() throws {
        var (t, a, b) = try pair(b: clip("B", start: 60, from: 8))
        let id = try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(10))
        try t.setTransition(id, duration: f(100))
        #expect(t.tracks[0].transitions[0].duration == f(17))      // before = 8 (B's head handle), after = 9
        #expect(t.resolvedTransitions(on: t.tracks[0].id)[0].isClamped == false)
    }

    @Test func linkedAudioAndVideoTransitionsAreIndependent() throws {
        let link1 = UUID(), link2 = UUID()
        let va = clip("A", start: 0, link: link1), vb = clip("B", start: 60, link: link2)
        let aa = clip("A", start: 0, kind: .audio, link: link1), ab = clip("B", start: 60, kind: .audio, link: link2)
        var v = Track(kind: .video), au = Track(kind: .audio)
        try v.overwrite(va); try v.overwrite(vb); try au.overwrite(aa); try au.overwrite(ab)
        var t = Timeline(name: "t", frameDuration: fd, tracks: [v, au])
        try t.addTransition(kind: .crossDissolve, track: v.id, outgoing: va.id, incoming: vb.id, duration: f(20))
        #expect(t.resolvedTransitions(on: au.id).isEmpty)
        try t.addTransition(kind: .constantPower, track: au.id, outgoing: aa.id, incoming: ab.id, duration: f(30))
        #expect(t.resolvedTransitions(on: v.id)[0].span.duration == f(20))
        #expect(t.resolvedTransitions(on: au.id)[0].span.duration == f(30))
        try t.removeTransition(t.tracks[1].transitions[0].id)
        #expect(t.resolvedTransitions(on: v.id).count == 1 && t.resolvedTransitions(on: au.id).isEmpty)
    }

    @Test func nearestEditPicksCutThenClipEdge() throws {
        var (t, a, b) = try pair()
        let tr = t.tracks[0].id
        #expect(t.transitionPoint(near: f(55), on: tr) == .cut(outgoing: a.id, incoming: b.id))
        #expect(t.transitionPoint(near: f(3), on: tr) == .head(a.id))
        #expect(t.transitionPoint(near: f(118), on: tr) == .tail(b.id))
        _ = try t.addTransition(point: .cut(outgoing: a.id, incoming: b.id), kind: .crossDissolve, track: tr, duration: f(10))
        #expect(t.tracks[0].transitions.count == 1)
    }

    @Test func defaultDurationIsOneSecondInWholeFrames() {
        #expect(Timeline.defaultTransitionDuration(frameDuration: Time(1001, 30000)) == Time(1001, 30000) * 30)
        #expect(Timeline.defaultTransitionDuration(frameDuration: Time(1, 25)) == Time(1, 25) * 25)
        #expect(Timeline.defaultTransitionDuration(frameDuration: Time(1, 24)) == Time(1, 24) * 24)
    }
}

@Suite struct TransitionEditConsistencyTests {
    private func setup() throws -> (Timeline, Track.ID, Clip, Clip, Transition.ID) {
        var (t, a, b) = try pair()
        let tr = t.tracks[0].id
        let id = try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(20))
        return (t, tr, a, b, id)
    }

    @Test func rollMovesTheTransitionWithTheCut() throws {
        var (t, tr, a, _, _) = try setup()
        _ = try t.roll(a.id, by: f(10))
        let r = try #require(t.resolvedTransitions(on: tr).first)
        #expect(r.cut == f(70) && r.span == TimeRange(start: f(60), duration: f(20)))
    }

    @Test func slipReclampsWhenTheHandleShrinks() throws {
        var (t, tr, _, b, _) = try setup()
        _ = try t.slip(b.id, by: f(-27))               // B now starts at source 3: head handle 3
        let r = try #require(t.resolvedTransitions(on: tr).first)
        #expect(r.isClamped && r.before <= f(3))
        _ = try t.slip(b.id, by: f(27))
        #expect(t.resolvedTransitions(on: tr)[0].span.duration == f(20))   // handle is back: requested length again
    }

    @Test func trimmingAClipEndAwayFromTheCutDropsTheTransition() throws {
        var (t, tr, a, _, _) = try setup()
        _ = try t.trim(a.id, edge: .tail, by: f(-10))   // leaves a gap: the cut is gone
        #expect(t.resolvedTransitions(on: tr).isEmpty)
        t.pruneTransitions()
        #expect(t.tracks[0].transitions.isEmpty)
    }

    @Test func rippleTrimKeepsTheCut() throws {
        var (t, tr, a, _, _) = try setup()
        _ = try t.rippleTrim(a.id, edge: .tail, by: f(-10))
        #expect(t.resolvedTransitions(on: tr).first?.cut == f(50))
    }

    @Test func moveAwayRemovesTheTransition() throws {
        var (t, tr, _, b, _) = try setup()
        _ = try t.move(b.id, to: f(100))
        #expect(t.resolvedTransitions(on: tr).isEmpty)
        t.pruneTransitions()
        #expect(t.tracks[0].transitions.isEmpty)
    }

    @Test func rippleDeleteDoesNotCreateATransitionBetweenNewNeighbours() throws {
        var (t, tr, a, b, _) = try setup()
        try t.tracks[0].overwrite(clip("C", start: 120))
        try t.rippleDelete([b.id])
        #expect(t.resolvedTransitions(on: tr).isEmpty)
        t.pruneTransitions()
        #expect(t.tracks[0].transitions.isEmpty)
        #expect(a.timeline.end == t.tracks[0].clips[1].start)
    }

    @Test func splittingEitherClipKeepsTheCutTransition() throws {
        var (t, tr, _, _, _) = try setup()
        var t2 = t
        try t2.tracks[0].split(at: f(30))               // inside A: the transition follows the right half, which touches B
        #expect(t2.resolvedTransitions(on: tr).count == 1)
        try t.tracks[0].split(at: f(90))                // inside B: B keeps the head with the old id
        #expect(t.resolvedTransitions(on: tr).count == 1)
    }

    @Test func speedChangeNeverLeavesAStaleTransition() throws {
        var (t, tr, a, _, _) = try setup()
        try t.setSpeed(a.id, to: ClipSpeed(percent: 50))   // A is longer now and ripples B
        for r in t.resolvedTransitions(on: tr) { #expect(r.span.start >= .zero && r.cut == t.tracks[0].clips[1].start) }
    }

    @Test func projectEditPrunesStaleTransitions() throws {
        let (t, _, _, b, _) = try setup()
        var p = Project(name: "p", timelines: [t])
        try p.edit(t.id) { _ = try $0.move(b.id, to: f(100)) }
        #expect(p.timelines[0].tracks[0].transitions.isEmpty)
    }

    @Test func pastedCopiesCarryTheirTransitionToo() throws {
        var (t, tr, a, b, _) = try setup()
        let cb = try #require(t.clipboard(copying: [a.id, b.id]))
        try t.paste(cb, at: f(200))
        #expect(t.resolvedTransitions(on: tr).count == 2)
    }
}

@Suite struct TransitionMixTests {
    @Test func crossDissolveWeightsAreStrictlyInsideAndSumToOne() {
        let n = 10
        var prev = 0.0
        for i in 0..<n {
            let w = TransitionMix.videoWeight(frameIndex: i, frames: n)
            #expect(w > prev && w < 1); prev = w
            let m = TransitionMix.video(.crossDissolve, weight: w)
            #expect(abs(m.outgoing + m.incoming - 1) < 1e-12 && m.dip == 0)
        }
        #expect(TransitionMix.videoWeight(frameIndex: 0, frames: 1) == 0.5)
    }

    @Test func dipMidpointIsFullyTheDipColour() {
        let m = TransitionMix.video(.dipToBlack, weight: 0.5)
        #expect(m.outgoing == 0 && m.incoming == 0 && m.dip == 1)
        let early = TransitionMix.video(.dipToWhite, weight: 0.25)
        #expect(abs(early.outgoing - 0.5) < 1e-12 && early.incoming == 0 && abs(early.dip - 0.5) < 1e-12)
        let late = TransitionMix.video(.dipToBlack, weight: 0.75)
        #expect(late.outgoing == 0 && abs(late.incoming - 0.5) < 1e-12)
        #expect(TransitionMix.dipColor(.dipToWhite) == [255, 255, 255] && TransitionMix.dipColor(.dipToBlack) == [0, 0, 0])
    }

    @Test func audioCurves() {
        let cp0 = TransitionMix.audioGains(.constantPower, progress: 0), cp1 = TransitionMix.audioGains(.constantPower, progress: 1)
        #expect(abs(cp0.outgoing - 1) < 1e-12 && abs(cp0.incoming) < 1e-12 && abs(cp1.outgoing) < 1e-12 && abs(cp1.incoming - 1) < 1e-12)
        for p in stride(from: 0.0, through: 1.0, by: 0.1) {
            let g = TransitionMix.audioGains(.constantPower, progress: p)
            #expect(abs(g.outgoing * g.outgoing + g.incoming * g.incoming - 1) < 1e-12)
            let l = TransitionMix.audioGains(.constantGain, progress: p)
            #expect(abs(l.outgoing + l.incoming - 1) < 1e-12)
        }
        #expect(abs(TransitionMix.audioGains(.constantPower, progress: 0.5).incoming - 0.5.squareRoot()) < 1e-12)
    }

    @Test func envelopeFollowsTheSpan() {
        let span = TimeRange(start: f(30), duration: f(30))
        let out = TransitionEnvelope(kind: .constantGain, span: span, role: .outgoing)
        let inn = TransitionEnvelope(kind: .constantGain, span: span, role: .incoming)
        #expect(out.gain(at: f(10)) == 1 && out.gain(at: f(70)) == 0)
        #expect(inn.gain(at: f(10)) == 0 && inn.gain(at: f(70)) == 1)
        #expect(abs(out.gain(at: f(45)) - 0.5) < 1e-12 && abs(inn.gain(at: f(45)) - 0.5) < 1e-12)
    }
}

@Suite struct TransitionEvaluationTests {
    @Test func layersInsideATransitionHaveBothClips() throws {
        var (t, a, b) = try pair()
        try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20))
        // outside the span: one layer, full opacity
        let before = t.videoLayers(at: f(40))
        #expect(before.count == 1 && before[0].clip == a.id && before[0].transform.opacity == 1)
        // first frame of the span (frame 50): A under B, B at weight 1/21
        let l = t.videoLayers(at: f(50))
        #expect(l.count == 2 && l[0].clip == a.id && l[1].clip == b.id)
        #expect(abs(l[0].transform.opacity - 20.0 / 21) < 1e-12 && abs(l[1].transform.opacity - 1.0 / 21) < 1e-12)
        #expect(l[0].pair?.role == .first && l[1].pair?.role == .second && l[0].pair?.id == l[1].pair?.id)
        #expect(before[0].pair == nil)
        // before the cut B plays 5 frames of its head handle
        let h = t.videoLayers(at: f(55))
        #expect(h[0].sourceTime == f(30 + 55) && h[1].sourceTime == f(30 - 5) && abs(h[1].transform.opacity - 6.0 / 21) < 1e-12)
        // after the cut A continues into its tail handle
        let m = t.videoLayers(at: f(65))
        #expect(m[0].clip == a.id && m[0].sourceTime == f(30 + 65) && m[1].clip == b.id && m[1].sourceTime == f(30 + 5))
        #expect(abs(m[1].transform.opacity - 16.0 / 21) < 1e-12)
        // after the span: only B
        let after = t.videoLayers(at: f(70))
        #expect(after.count == 1 && after[0].clip == b.id)
    }

    @Test func dipAddsASolidLayerBelow() throws {
        var (t, a, b) = try pair()
        try t.addTransition(kind: .dipToWhite, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(21), alignment: .startAtCut)
        let l = t.videoLayers(at: f(60 + 10))    // frame 10 of 21: weight 11/22 = 0.5 -> pure white
        #expect(l.count == 3)
        #expect(l[0].generator?.kind == GeneratorRef.solid && l[0].generator?.payload == Data([255, 255, 255]))
        #expect(l[0].transform.opacity == 1 && l[1].transform.opacity == 0 && l[2].transform.opacity == 0)
    }

    @Test func reversedOutgoingClipExtendsPastItsEnd() throws {
        let rev = clip("A", start: 0, from: 30, frames: 60, media: 300, reversed: true)
        var (t, a, b) = try pair(a: rev)
        try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20), alignment: .startAtCut)
        let l = t.videoLayers(at: f(62))     // 2 frames after A's end: reversed A runs below source.start
        #expect(l[0].clip == a.id && l[0].sourceTime < f(30))
    }

    @Test func headFadeOnASingleClip() throws {
        var (t, a, _) = try pair()
        try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: nil, incoming: a.id, duration: f(9))
        let l = t.videoLayers(at: f(0))
        #expect(l.count == 1 && abs(l[0].transform.opacity - 0.1) < 1e-12)
        #expect(t.videoLayers(at: f(9))[0].transform.opacity == 1)
    }

    @Test func audioSegmentsExtendIntoHandlesWithEnvelopes() throws {
        var (t, a, b) = try pair(kind: .audio)
        try t.addTransition(kind: .constantPower, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20))
        let segs = t.audioSegments(in: TimeRange(start: .zero, duration: f(200)))
        let sa = try #require(segs.first { $0.clip == a.id }), sb = try #require(segs.first { $0.clip == b.id })
        #expect(sa.timeline == TimeRange(start: f(0), duration: f(70)) && sb.timeline == TimeRange(start: f(50), duration: f(70)))
        #expect(sa.sourceStart == f(30) && sb.sourceStart == f(30 - 10))
        #expect(sa.source.end == f(30 + 60 + 10) && sb.source.start == f(20))
        let ea = try #require(sa.envelopes.first), eb = try #require(sb.envelopes.first)
        #expect(ea.role == .outgoing && eb.role == .incoming && ea.span == TimeRange(start: f(50), duration: f(20)))
        #expect(sa.envelopeGain(at: f(10)) == 1 && sa.envelopeGain(at: f(69)) < 0.1)
        #expect(sb.envelopeGain(at: f(50)) < 0.01)
    }
}

@Suite struct TransitionBudgetTests {
    /// A 10-frame clip B between two long ones, with two 8-frame transitions on it (one on each edge).
    private func shortMiddle(kind: TrackKind = .video, alignment: TransitionAlignment = .startAtCut) throws -> (Timeline, Clip, Clip, Clip) {
        let a = clip("A", start: 0, kind: kind), b = clip("B", start: 60, frames: 10, kind: kind), c = clip("C", start: 70, kind: kind)
        var t = Track(kind: kind)
        for x in [a, b, c] { try t.overwrite(x) }
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [t])
        let video = kind == .video
        try tl.addTransition(kind: video ? .crossDissolve : .constantPower, track: t.id, outgoing: a.id, incoming: b.id, duration: f(8), alignment: alignment)
        try tl.addTransition(kind: video ? .crossDissolve : .constantPower, track: t.id, outgoing: b.id, incoming: c.id, duration: f(8), alignment: .endAtCut)
        return (tl, a, b, c)
    }

    @Test func aClipNeverHoldsMoreTransitionFramesThanItsLength() throws {
        let (t, _, b, _) = try shortMiddle()
        let rs = t.resolvedTransitions(on: t.tracks[0].id)
        #expect(rs.count == 2)
        let head = rs[0], tail = rs[1]                       // timeline order
        #expect(head.span.duration == f(8))                  // the earlier one keeps its request
        #expect(tail.span.duration == f(2))                  // the later one gets the 2 frames left in B
        #expect(head.after + tail.before <= b.timeline.duration)
    }

    @Test func videoAndAudioAgreeOnTheClampedSpans() throws {
        let (v, _, _, _) = try shortMiddle(kind: .video)
        let (au, _, _, _) = try shortMiddle(kind: .audio)
        let vs = v.resolvedTransitions(on: v.tracks[0].id).map(\.span), asp = au.resolvedTransitions(on: au.tracks[0].id).map(\.span)
        #expect(vs == asp)
        // Video: inside the overlap-free part of B exactly one transition is active per frame (no storage-order lottery).
        for n in 60..<70 {
            let layers = v.videoLayers(at: f(Int64(n)))
            #expect(layers.count == 2 || layers.count == 1)
        }
        // Audio: B's envelopes cover disjoint spans, so their product never dips below either alone.
        let seg = au.audioSegments(in: TimeRange(start: f(55), duration: f(30))).first { $0.envelopes.count == 2 }
        let e = try #require(seg).envelopes
        #expect(e[0].span.end <= e[1].span.start)
    }

    @Test func settingADurationOnTheLaterTransitionClampsToTheRemainder() throws {
        var (t, _, _, _) = try shortMiddle()
        let tid = t.tracks[0].transitions[1].id
        try t.setTransition(tid, duration: f(30))
        #expect(t.resolvedTransitions(on: t.tracks[0].id)[1].span.duration == f(2))
        #expect(t.tracks[0].transitions[1].duration == f(2))
    }
}

@Suite struct TransitionSplitTests {
    @Test func splittingTheOutgoingClipKeepsTheCutTransitionOnTheRightHalf() throws {
        var (t, a, b) = try pair()
        let tr = t.tracks[0].id
        try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(20))
        try t.tracks[0].split(at: f(30))
        let rs = t.resolvedTransitions(on: tr)
        #expect(rs.count == 1 && rs[0].outgoing != a.id && rs[0].incoming == b.id && rs[0].cut == f(60))
        t.pruneTransitions()
        #expect(t.tracks[0].transitions.count == 1)
    }

    @Test func splittingAClipMovesItsTailFadeToTheRightHalfAndKeepsTheHeadFade() throws {
        var (t, a, _) = try pair()
        let tr = t.tracks[0].id
        try t.addTransition(kind: .dipToBlack, track: tr, outgoing: nil, incoming: a.id, duration: f(10))
        try t.addTransition(kind: .dipToBlack, track: tr, outgoing: a.id, incoming: nil, duration: f(10))
        try t.tracks[0].split(at: f(30))
        let rs = t.resolvedTransitions(on: tr)
        let left = t.tracks[0].clips[0], right = t.tracks[0].clips[1]
        #expect(left.id == a.id)
        #expect(rs.first { $0.incoming == a.id && $0.outgoing == nil }?.span == TimeRange(start: .zero, duration: f(10)))
        #expect(rs.first { $0.outgoing == right.id && $0.incoming == nil }?.span == TimeRange(start: f(50), duration: f(10)))
        #expect(rs.count == 2)
    }

    @Test func addEditAndRazorGoThroughTheSamePath() throws {
        var (t, a, b) = try pair()
        let tr = t.tracks[0].id
        try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(20))
        _ = try t.addEdit(at: f(20), tracks: nil)
        #expect(t.resolvedTransitions(on: tr).count == 1)
    }
}

@Suite struct TransitionClipboardTests {
    @Test func copyingTwoAdjacentClipsCopiesTheirCutTransition() throws {
        var (t, a, b) = try pair()
        let tr = t.tracks[0].id
        try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(20))
        try t.addTransition(kind: .dipToBlack, track: tr, outgoing: b.id, incoming: nil, duration: f(10))
        let cb = try #require(t.clipboard(copying: [a.id, b.id]))
        #expect(cb.transitions.count == 2)
        try t.paste(cb, at: f(200))
        let rs = t.resolvedTransitions(on: tr)
        #expect(rs.count == 4)
        let copies = rs.filter { $0.span.start >= f(190) }
        #expect(copies.count == 2 && copies.contains { $0.kind == .crossDissolve && $0.cut == f(260) })
        #expect(Set(copies.map(\.id)).isDisjoint(with: Set(rs.filter { $0.span.start < f(190) }.map(\.id))))
    }

    @Test func copyingOneClipOfACutLeavesTheTransitionBehind() throws {
        var (t, a, b) = try pair()
        let tr = t.tracks[0].id
        try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(20))
        let cb = try #require(t.clipboard(copying: [b.id]))
        #expect(cb.transitions.isEmpty)
        try t.paste(cb, at: f(200))
        #expect(t.resolvedTransitions(on: tr).count == 1)
    }

    @Test func insertPasteKeepsTheCopiedTransition() throws {
        var (t, a, b) = try pair()
        let tr = t.tracks[0].id
        try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(20))
        let cb = try #require(t.clipboard(copying: [a.id, b.id]))
        try t.paste(cb, at: f(120), insert: true)
        #expect(t.resolvedTransitions(on: tr).count == 2)
    }
}

@Suite struct TransitionRound2EditTests {
    @Test func aDisabledNeighbourNeverShowsInADissolve() throws {
        var (t, a, b) = try pair()
        let tr = t.tracks[0].id
        try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(20))
        _ = try t.toggleEnabled([a.id])                                   // A disabled
        var l = t.videoLayers(at: f(55))
        #expect(l.count == 1 && l[0].clip == b.id && l[0].pair == nil && abs(l[0].transform.opacity - 6.0 / 21) < 1e-12)
        _ = try t.toggleEnabled([a.id]); _ = try t.toggleEnabled([b.id])  // A back, B disabled
        l = t.videoLayers(at: f(65))
        #expect(l.count == 1 && l[0].clip == a.id && abs(l[0].transform.opacity - 5.0 / 21) < 1e-12)
        #expect(t.videoLayers(at: f(100)).isEmpty)                         // outside the span a disabled clip is simply absent
        _ = try t.toggleEnabled([a.id])                                   // both disabled
        #expect(t.videoLayers(at: f(55)).isEmpty)
    }

    @Test func aDisabledNeighbourIsSilentInAnAudioCrossfade() throws {
        var (t, a, b) = try pair(kind: .audio)
        try t.addTransition(kind: .constantPower, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20))
        _ = try t.toggleEnabled([a.id])
        let segs = t.audioSegments(in: TimeRange(start: .zero, duration: f(200)))
        #expect(segs.count == 1 && segs[0].clip == b.id)
        _ = try t.toggleEnabled([a.id])
        #expect(t.audioSegments(in: TimeRange(start: .zero, duration: f(200))).count == 2)
    }

    @Test func dipWithADisabledSideStillDips() throws {
        var (t, a, b) = try pair()
        try t.addTransition(kind: .dipToBlack, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(21), alignment: .startAtCut)
        _ = try t.toggleEnabled([b.id])
        let l = t.videoLayers(at: f(60 + 5))                                // first half: A fades to black
        #expect(l.count == 2 && l[0].generator?.kind == GeneratorRef.solid && l[1].clip == a.id)
    }

    @Test func duplicateCopiesTheTransitionOfAdjacentClipsAsOneStep() throws {
        var (t, a, b) = try pair()
        let tr = t.tracks[0].id
        try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(20))
        let made = try t.duplicate([a.id, b.id])
        #expect(made.count == 2)
        let rs = t.resolvedTransitions(on: tr)
        #expect(rs.count == 2 && rs.contains { $0.outgoing == made[0] || $0.incoming == made[1] })
        var p = Project(name: "p", timelines: [t])
        try p.edit(t.id) { _ = try $0.duplicate([made[0], made[1]]) }
        #expect(p.timelines[0].tracks[0].transitions.count == 3)
    }

    @Test func rearrangingOneClipOfACutDropsItsTransitionAndKeepsTheRest() throws {
        var (t, a, b) = try pair()
        let tr = t.tracks[0].id
        try t.tracks[0].overwrite(clip("C", start: 120))
        let c = t.tracks[0].clips[2]
        try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(20))
        try t.addTransition(kind: .crossDissolve, track: tr, outgoing: b.id, incoming: c.id, duration: f(20))
        var p = Project(name: "p", timelines: [t])
        try p.edit(t.id) { try $0.moveInsert(a.id, to: f(120)) }          // A lands between B and C: A|B and B|C are both gone
        let rest = p.timelines[0].tracks[0]
        #expect(rest.clips.map(\.id) == [b.id, a.id, c.id])
        #expect(rest.transitions.isEmpty)
        // Rearranging so that the pair stays adjacent keeps its transition (undo is one snapshot either way).
        var q = Project(name: "q", timelines: [t])
        try q.edit(t.id) { try $0.moveInsert(c.id, to: .zero) }           // C to the front: A|B untouched
        #expect(q.timelines[0].tracks[0].transitions.contains { $0.outgoing == a.id && $0.incoming == b.id })
        #expect(!q.timelines[0].tracks[0].transitions.contains { $0.outgoing == b.id })
    }

    @Test func insertMoveAndInsertCopyKeepEverythingConsistent() throws {
        var (t, a, b) = try pair()
        let tr = t.tracks[0].id
        try t.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(20))
        var p = Project(name: "p", timelines: [t])
        // Insert a copy of B in the middle of A: A is split, its tail transition follows the right half.
        try p.edit(t.id) { try $0.insertCopy(b.id, to: f(30), copy: CopySpec()) }
        let tl = p.timelines[0]
        for r in tl.resolvedTransitions(on: tr) { #expect(r.span.start >= .zero) }
        #expect(tl.tracks[0].transitions.allSatisfy { x in tl.resolvedTransitions(on: tr).contains { $0.id == x.id } })
        #expect(tl.resolvedTransitions(on: tr).count == 1)
    }
}

