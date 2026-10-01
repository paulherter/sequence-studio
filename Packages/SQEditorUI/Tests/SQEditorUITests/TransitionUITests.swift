import CoreGraphics
import Foundation
import Testing
import SQCore
@testable import SQEditorUI

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

private func clip(_ name: String, start: Int64, from: Int64 = 30, frames: Int64 = 60, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: name, media: UUID(), kind: kind, source: TimeRange(start: f(from), duration: f(frames)), start: f(start),
         link: link, mediaDuration: f(300))
}

/// V1: A 0..60, B 60..120, gap, C 150..210; A1: a 0..60, b 60..120. V1 and A1 targeted.
@MainActor private func makeSession() throws -> (EditorSession, Timeline, [String: Clip]) {
    let l1 = UUID(), l2 = UUID()
    let a = clip("A", start: 0, link: l1), b = clip("B", start: 60, link: l2), c = clip("C", start: 150)
    let aa = clip("a", start: 0, kind: .audio, link: l1), ab = clip("b", start: 60, kind: .audio, link: l2)
    var v = Track(kind: .video, isTargeted: true), au = Track(kind: .audio, isTargeted: true)
    for x in [a, b, c] { try v.overwrite(x) }
    for x in [aa, ab] { try au.overwrite(x) }
    let tl = Timeline(name: "T", frameDuration: fd, tracks: [v, au])
    let session = EditorSession(project: Project(name: "p", timelines: [tl]))
    return (session, tl, ["A": a, "B": b, "C": c, "a": aa, "b": ab])
}

private let defaults = TransitionDefaults(videoFrames: 20, audioSeconds: 1)

@Suite struct TransitionTargetsTests {
    @MainActor @Test func playheadTakesTheNearestEditOnTargetedTracksOfTheScope() throws {
        let (_, t, c) = try makeSession()
        let both = TransitionTargets.resolve(in: t, kinds: [.video, .audio], edges: nil, selection: [], playhead: f(58))
        #expect(Set(both.map(\.point)) == [.cut(outgoing: c["A"]!.id, incoming: c["B"]!.id), .cut(outgoing: c["a"]!.id, incoming: c["b"]!.id)])
        let video = TransitionTargets.resolve(in: t, kinds: [.video], edges: nil, selection: [], playhead: f(58))
        #expect(video.count == 1 && video[0].track == t.tracks[0].id)
        // Far from any cut but near the clip end in the gap: the tail of B.
        let gap = TransitionTargets.resolve(in: t, kinds: [.video], edges: nil, selection: [], playhead: f(130))
        #expect(gap.map(\.point) == [.tail(c["B"]!.id)])
    }

    @MainActor @Test func selectedEdgeBeatsSelectionAndPlayhead() throws {
        let (_, t, c) = try makeSession()
        let edges = EdgeSelection(edges: [EdgeRef(clip: c["B"]!.id, edge: .head)])
        let r = TransitionTargets.resolve(in: t, kinds: [.video, .audio], edges: edges, selection: [c["C"]!.id], playhead: f(150))
        #expect(r.map(\.point) == [.cut(outgoing: c["A"]!.id, incoming: c["B"]!.id)])
    }

    @MainActor @Test func selectedClipsGetBothEdges() throws {
        let (_, t, c) = try makeSession()
        let r = TransitionTargets.resolve(in: t, kinds: [.video], edges: nil, selection: [c["B"]!.id], playhead: .zero)
        #expect(Set(r.map(\.point)) == [.cut(outgoing: c["A"]!.id, incoming: c["B"]!.id), .tail(c["B"]!.id)])
        let lone = TransitionTargets.resolve(in: t, kinds: [.video], edges: nil, selection: [c["C"]!.id], playhead: .zero)
        #expect(Set(lone.map(\.point)) == [.head(c["C"]!.id), .tail(c["C"]!.id)])
    }

    @MainActor @Test func lockedAndUntargetedTracksAreSkipped() throws {
        var (_, t, _) = try makeSession()
        t.tracks[0].isTargeted = false
        #expect(TransitionTargets.resolve(in: t, kinds: [.video], edges: nil, selection: [], playhead: f(58)).isEmpty)
        t.tracks[0].isTargeted = true; t.tracks[0].isLocked = true
        #expect(TransitionTargets.resolve(in: t, kinds: [.video], edges: nil, selection: [], playhead: f(58)).isEmpty)
    }

    @Test func defaultDurations() {
        #expect(TransitionDefaults.standard.duration(for: .video, frameDuration: Time(1001, 30000)) == Time(1001, 30000) * 30)
        #expect(TransitionDefaults.standard.duration(for: .audio, frameDuration: Time(1, 25)) == Time(1, 25) * 25)
        #expect(TransitionDefaults(videoFrames: 12, audioSeconds: 0.5).duration(for: .video, frameDuration: fd) == f(12))
        #expect(TransitionDefaults(videoFrames: 12, audioSeconds: 0.5).duration(for: .audio, frameDuration: fd) == f(15))
    }

    @Test func defaultsRoundTripAndRejectGarbage() {
        let d = UserDefaults(suiteName: "TransitionDefaultsTests-\(UUID())")!
        #expect(TransitionDefaults.load(from: d) == .standard)
        TransitionDefaults(videoFrames: 18, audioSeconds: 2.5).save(to: d)
        #expect(TransitionDefaults.load(from: d) == TransitionDefaults(videoFrames: 18, audioSeconds: 2.5))
        d.set(-4, forKey: TransitionDefaults.Key.video); d.set(0.0, forKey: TransitionDefaults.Key.audio)
        #expect(TransitionDefaults.load(from: d) == .standard)
    }
}

@Suite struct TransitionSessionTests {
    @MainActor @Test func applyDefaultIsOneUndoStepAndReplacesOnSecondApply() throws {
        let (s, _, c) = try makeSession()
        s.seek(to: f(58))
        #expect(s.applyDefaultTransitions(scope: .both, edges: nil, defaults: defaults) == 2)
        #expect(s.undoName == "Apply Transitions")
        let tl = s.activeTimeline!
        #expect(tl.tracks[0].transitions.count == 1 && tl.tracks[1].transitions.count == 1)
        #expect(tl.tracks[0].transitions[0].kind == .crossDissolve && tl.tracks[0].transitions[0].duration == f(20))
        #expect(tl.tracks[1].transitions[0].kind == .constantPower && tl.tracks[1].transitions[0].duration == f(30))
        #expect(s.applyDefaultTransitions(scope: .video, edges: nil, defaults: defaults) == 1)
        #expect(s.activeTimeline!.tracks[0].transitions.count == 1)          // replaced, not stacked
        s.undo(); s.undo()
        #expect(s.activeTimeline!.tracks.allSatisfy { $0.transitions.isEmpty })
        _ = c
    }

    @MainActor @Test func noEditToApplyOnSetsAMessage() throws {
        let (s, _, _) = try makeSession()
        try s.performTimeline("Untarget") { $0.tracks[0].isTargeted = false }
        #expect(s.applyDefaultTransitions(scope: .video, edges: nil, defaults: defaults) == 0)
        #expect(s.lastError != nil)
    }

    @MainActor @Test func notEnoughMediaIsRefusedWithoutAChange() throws {
        // A uses the end of its media and B the start: nothing beyond the cut.
        let a = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: f(240), duration: f(60)), start: .zero, mediaDuration: f(300))
        let b = Clip(name: "B", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: f(60), mediaDuration: f(300))
        var v = Track(kind: .video, isTargeted: true); try v.overwrite(a); try v.overwrite(b)
        let s = EditorSession(project: Project(name: "p", timelines: [Timeline(name: "T", frameDuration: fd, tracks: [v])]))
        s.seek(to: f(58))
        #expect(s.applyDefaultTransitions(scope: .video, edges: nil, defaults: defaults) == 0)
        #expect(s.activeTimeline!.tracks[0].transitions.isEmpty && !s.canUndo)
        #expect(s.lastError?.contains("Not enough media") == true)
    }

    @MainActor @Test func dropOnACutHonoursAlignmentAndSelectsIt() throws {
        let (s, _, c) = try makeSession()
        let tr = s.activeTimeline!.tracks[0].id
        let id = try #require(s.addTransition(kind: .dipToBlack, track: tr, point: .cut(outgoing: c["A"]!.id, incoming: c["B"]!.id),
                                              alignment: .endAtCut, defaults: defaults))
        #expect(s.selectedTransition == id)
        let r = s.activeTimeline!.resolvedTransitions(on: tr)[0]
        #expect(r.span == TimeRange(start: f(40), duration: f(20)) && r.kind == .dipToBlack)
        #expect(s.undoName == "Apply Dip to Black")
    }

    @MainActor @Test func dragEditsOfOneGestureAreOneUndoStep() throws {
        let (s, _, c) = try makeSession()
        let tr = s.activeTimeline!.tracks[0].id
        let id = try #require(s.addTransition(kind: .crossDissolve, track: tr, point: .cut(outgoing: c["A"]!.id, incoming: c["B"]!.id),
                                              alignment: .center, defaults: defaults))
        let depth = s.history.undoDepth
        s.setTransition(id, duration: f(24))
        s.setTransition(id, duration: f(26), continuesGesture: true)
        s.setTransition(id, duration: f(28), continuesGesture: true)
        #expect(s.history.undoDepth == depth + 1 && s.activeTimeline!.tracks[0].transitions[0].duration == f(28))
        s.undo()
        #expect(s.activeTimeline!.tracks[0].transitions[0].duration == f(20))
    }

    @MainActor @Test func deleteRemovesTheSelectedTransition() throws {
        let (s, _, c) = try makeSession()
        let tr = s.activeTimeline!.tracks[0].id
        _ = s.addTransition(kind: .crossDissolve, track: tr, point: .cut(outgoing: c["A"]!.id, incoming: c["B"]!.id),
                            alignment: .center, defaults: defaults)
        #expect(s.removeSelectedTransition())
        #expect(s.activeTimeline!.tracks[0].transitions.isEmpty && s.selectedTransition == nil)
        #expect(!s.removeSelectedTransition())
        s.undo()
        #expect(s.activeTimeline!.tracks[0].transitions.count == 1)
    }

    @MainActor @Test func selectionFollowsClipsAndUndo() throws {
        let (s, _, c) = try makeSession()
        let tr = s.activeTimeline!.tracks[0].id
        _ = s.addTransition(kind: .crossDissolve, track: tr, point: .cut(outgoing: c["A"]!.id, incoming: c["B"]!.id),
                            alignment: .center, defaults: defaults)
        #expect(s.selectedTransition != nil)
        s.select(clips: [c["C"]!.id])
        #expect(s.selectedTransition == nil)
        s.undo()
        #expect(s.selectedTransition == nil)
    }
}

@Suite struct TransitionLayoutTests {
    private func resolved(alignment: TransitionAlignment = .center, frames: Int64 = 20) throws -> (ResolvedTransition, Timeline) {
        let a = clip("A", start: 0), b = clip("B", start: 60)
        var tr = Track(kind: .video); try tr.overwrite(a); try tr.overwrite(b)
        var t = Timeline(name: "t", frameDuration: fd, tracks: [tr])
        try t.addTransition(kind: .crossDissolve, track: tr.id, outgoing: a.id, incoming: b.id, duration: f(frames), alignment: alignment)
        return (t.resolvedTransitions(on: tr.id)[0], t)
    }

    @Test func centredDragIsSymmetricAndShiftMovesOneSide() throws {
        let (r, _) = try resolved()
        let right = TransitionLayout.drag(r, zone: .rightEdge, frames: 3, oneSide: false)
        #expect(right.duration == f(26) && right.alignment == .center)
        let left = TransitionLayout.drag(r, zone: .leftEdge, frames: -3, oneSide: false)
        #expect(left.duration == f(26) && left.alignment == .center)
        let shiftRight = TransitionLayout.drag(r, zone: .rightEdge, frames: 3, oneSide: true)
        #expect(shiftRight.duration == f(23) && shiftRight.alignment == .custom && shiftRight.customBefore == f(10))
        let shiftLeft = TransitionLayout.drag(r, zone: .leftEdge, frames: -4, oneSide: true)
        #expect(shiftLeft.duration == f(24) && shiftLeft.alignment == .custom && shiftLeft.customBefore == f(14))
        // never below one frame
        #expect(TransitionLayout.drag(r, zone: .rightEdge, frames: -50, oneSide: false).duration == f(1))
    }

    @Test func nonCentredEdgesMoveOnlyTheDraggedSide() throws {
        let (r, _) = try resolved(alignment: .startAtCut)
        let longer = TransitionLayout.drag(r, zone: .rightEdge, frames: 5, oneSide: false)
        #expect(longer.duration == f(25) && longer.alignment == .startAtCut)
        let left = TransitionLayout.drag(r, zone: .leftEdge, frames: -5, oneSide: false)      // pulls the start before the cut
        #expect(left.duration == f(25) && left.alignment == .custom && left.customBefore == f(5))
        let (e, _) = try resolved(alignment: .endAtCut)
        #expect(TransitionLayout.drag(e, zone: .rightEdge, frames: -4, oneSide: false).duration == f(20))   // the cut stays inside
    }

    @Test func bodyDragMovesAlignmentOverTheCut() throws {
        let (r, _) = try resolved()
        let right = TransitionLayout.drag(r, zone: .body, frames: 4, oneSide: false)
        #expect(right.alignment == .custom && right.customBefore == f(6) && right.duration == f(20))
        #expect(TransitionLayout.drag(r, zone: .body, frames: 10, oneSide: false).alignment == .startAtCut)
        #expect(TransitionLayout.drag(r, zone: .body, frames: 99, oneSide: false).alignment == .startAtCut)
        #expect(TransitionLayout.drag(r, zone: .body, frames: -10, oneSide: false).alignment == .endAtCut)
        #expect(TransitionLayout.drag(r, zone: .body, frames: 0, oneSide: false).alignment == .center)
    }

    @Test func singleSidedOnlyChangesLengthAtTheFreeEdge() throws {
        let a = clip("A", start: 0)
        var tr = Track(kind: .video); try tr.overwrite(a)
        var t = Timeline(name: "t", frameDuration: fd, tracks: [tr])
        try t.addTransition(kind: .dipToBlack, track: tr.id, outgoing: nil, incoming: a.id, duration: f(10))
        try t.addTransition(kind: .dipToBlack, track: tr.id, outgoing: a.id, incoming: nil, duration: f(10))
        let rs = t.resolvedTransitions(on: tr.id)
        let head = rs.first { $0.outgoing == nil }!, tail = rs.first { $0.incoming == nil }!
        #expect(TransitionLayout.drag(head, zone: .rightEdge, frames: 5, oneSide: false).duration == f(15))
        #expect(TransitionLayout.drag(head, zone: .leftEdge, frames: -5, oneSide: false).duration == f(10))
        #expect(TransitionLayout.drag(head, zone: .body, frames: 5, oneSide: false).duration == f(10))
        #expect(TransitionLayout.drag(tail, zone: .leftEdge, frames: -5, oneSide: false).duration == f(15))
        #expect(TransitionLayout.drag(tail, zone: .rightEdge, frames: 5, oneSide: false).duration == f(10))
    }

    @Test func boxesAreHitOverTheClipsWithEdgeZones() throws {
        let (r, t) = try resolved()
        let g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 10)
        let row = g.rows(for: t)[0]
        let box = TransitionLayout.rect(r, row: row, geometry: g)
        #expect(abs(box.minX - g.x(for: f(50))) < 1e-9 && abs(box.width - 200) < 1e-9)
        let y = row.y + row.height / 2
        #expect(TransitionLayout.hitTest(CGPoint(x: box.midX - 30, y: y), in: t, geometry: g)?.zone == .body)
        #expect(TransitionLayout.hitTest(CGPoint(x: box.midX + 4, y: y), in: t, geometry: g) == nil)      // the clip edge at the cut wins
        #expect(TransitionLayout.hitTest(CGPoint(x: box.midX - 4, y: y), in: t, geometry: g) == nil)
        #expect(TransitionLayout.hitTest(CGPoint(x: box.minX + 1, y: y), in: t, geometry: g)?.zone == .leftEdge)
        #expect(TransitionLayout.hitTest(CGPoint(x: box.maxX - 1, y: y), in: t, geometry: g)?.zone == .rightEdge)
        #expect(TransitionLayout.hitTest(CGPoint(x: box.minX - 2, y: y), in: t, geometry: g) == nil)
        #expect(TransitionLayout.hitTest(CGPoint(x: box.midX, y: row.maxY + 5), in: t, geometry: g) == nil)
        // a one-frame transition at a very low zoom stays clickable
        let thin = TimelineGeometry(frameDuration: fd, pointsPerFrame: 0.2)
        let (one, t1) = try resolved(frames: 1)
        let r1 = TransitionLayout.rect(one, row: thin.rows(for: t1)[0], geometry: thin)
        #expect(r1.width >= TransitionLayout.minWidth)
    }

    @Test func dropTargetPicksSideFromPointerAndMatchesTrackKind() throws {
        let (_, t) = try resolved()
        let g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 10)
        let row = g.rows(for: t)[0]
        let cutX = g.x(for: f(60)), y = row.y + 5
        let centre = TransitionLayout.dropTarget(at: CGPoint(x: cutX + 3, y: y), kind: .crossDissolve, in: t, geometry: g)
        #expect(centre?.alignment == .center)
        #expect(TransitionLayout.dropTarget(at: CGPoint(x: cutX - 20, y: y), kind: .crossDissolve, in: t, geometry: g)?.alignment == .endAtCut)
        #expect(TransitionLayout.dropTarget(at: CGPoint(x: cutX + 20, y: y), kind: .crossDissolve, in: t, geometry: g)?.alignment == .startAtCut)
        #expect(TransitionLayout.dropTarget(at: CGPoint(x: cutX + 200, y: y), kind: .crossDissolve, in: t, geometry: g) == nil)    // far from any edit
        #expect(TransitionLayout.dropTarget(at: CGPoint(x: cutX, y: y), kind: .constantPower, in: t, geometry: g) == nil)         // audio onto video
        let head = TransitionLayout.dropTarget(at: CGPoint(x: g.x(for: .zero) + 4, y: y), kind: .dipToWhite, in: t, geometry: g)
        #expect(head?.alignment == .startAtCut)
        if case .head = head?.point {} else { Issue.record("expected a head target") }
    }
}

@Suite struct TransitionStaleSelectionTests {
    @MainActor @Test func deleteFallsThroughWhenTheSelectedTransitionIsGone() throws {
        let (s, _, c) = try makeSession()
        let tr = s.activeTimeline!.tracks[0].id
        _ = s.addTransition(kind: .crossDissolve, track: tr, point: .cut(outgoing: c["A"]!.id, incoming: c["B"]!.id),
                            alignment: .center, defaults: defaults)
        #expect(s.selectedTransition != nil)
        s.undo()                                                        // the transition is gone with the undo
        #expect(s.selectedTransition == nil)
        #expect(!s.removeSelectedTransition())
        // Even a selection that is still set but whose transition vanished must not swallow Delete.
        s.selectTransition(UUID())
        #expect(!s.removeSelectedTransition() && s.selectedTransition == nil)
        #expect(s.lastError == nil)
    }
}
