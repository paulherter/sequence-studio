import Foundation
import Testing
@testable import SQCore

// Transition layer (DECISIONS 2026-10-05): a transition placed as its own clip on a video track. It transitions everything
// composited below that track: before its cut the stack below is the outgoing side, from the cut on the incoming side.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

@Suite struct TransitionLayerTests {
    /// V1 + V2 hold pictures, V3 takes the transition layer, V4 holds a title above it.
    private func project() -> (Project, Timeline.ID, [Track.ID]) {
        let tracks = (0..<4).map { _ in Track(kind: .video) } + [Track(kind: .audio)]
        let t = Timeline(name: "T", frameDuration: fd, tracks: tracks)
        return (Project(name: "P", timelines: [t]), t.id, tracks.map(\.id))
    }

    private func media(_ name: String, start: Int64, frames: Int64, sourceStart: Int64 = 0) -> Clip {
        Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: f(sourceStart), duration: f(frames)), start: f(start))
    }

    private func clip(_ p: Project, _ tl: Timeline.ID, _ id: Clip.ID) -> Clip {
        p.timeline(tl)!.tracks.flatMap(\.clips).first { $0.id == id }!
    }

    /// A on V1 frames 0..<30, B on V1 30..<60 (cut at 30); a b-roll on V2 over the whole range; transition layer on V3
    /// frames 20..<40 (cut 30).
    private func stack(kind: TransitionKind = .crossDissolve) throws -> (Project, Timeline.ID, [Track.ID], a: Clip, b: Clip, broll: Clip, layer: Clip.ID) {
        var (p, tl, ids) = project()
        let a = media("A", start: 0, frames: 30), b = media("B", start: 30, frames: 30, sourceStart: 100)
        let broll = media("R", start: 0, frames: 60)
        try p.edit(tl) {
            try $0.tracks[0].overwrite(a); try $0.tracks[0].overwrite(b); try $0.tracks[1].overwrite(broll)
        }
        let id = try p.addTransitionLayer(kind: kind, in: tl, at: f(20), track: ids[2], duration: f(20))
        return (p, tl, ids, a, b, broll, id)
    }

    // MARK: Model

    @Test func placingCreatesAGeneratorClipWithItsCutInTheMiddle() throws {
        let (p, tl, _, _, _, _, id) = try stack()
        let c = clip(p, tl, id)
        #expect(c.isTransitionLayer && c.isGenerator && c.kind == .video)
        #expect(!c.isAdjustment)
        #expect(c.name == "Transition Layer")
        #expect(c.timeline == TimeRange(start: f(20), duration: f(20)))
        #expect(c.transitionLayer?.kind == .crossDissolve)
        #expect(c.transitionLayerCut == f(30))
        let r = try #require(c.resolvedTransitionLayer(frameDuration: fd))
        #expect(r.cut == f(30) && r.span == c.timeline && r.before == f(10) && r.after == f(10))
        #expect(r.frames == 20 && r.alignment == .center)
    }

    @Test func placingAnOddLengthPutsTheCutOnAFrameBeforeTheMiddle() throws {
        var (p, tl, ids) = project()
        let id = try p.addTransitionLayer(kind: .push, in: tl, at: f(0), track: ids[0], duration: f(7))
        #expect(clip(p, tl, id).transitionLayerCut == f(3))
    }

    @Test func refusesAudioTracksAndKindsWithoutTwoPictures() throws {
        var (p, tl, ids) = project()
        #expect(throws: EditError.wrongTrackKind) { try p.addTransitionLayer(kind: .crossDissolve, in: tl, at: .zero, track: ids[4], duration: f(10)) }
        for k in [TransitionKind.stinger, .move, .zoom, .pop, .constantPower] {
            #expect(!k.isLayerKind)
            #expect(throws: EditError.wrongTrackKind) { try p.addTransitionLayer(kind: k, in: tl, at: .zero, track: ids[0], duration: f(10)) }
        }
        #expect(TransitionKind.layerKinds.contains(.crossDissolve) && TransitionKind.layerKinds.contains(.whip))
        #expect(throws: EditError.emptyClip) { try p.addTransitionLayer(kind: .crossDissolve, in: tl, at: .zero, track: ids[0], duration: .zero) }
    }

    @Test func movingTheCutClampsToTheClipAndSnapsToFrames() throws {
        var (p, tl, _, _, _, _, id) = try stack()
        var applied = Time.zero
        try p.edit(tl) { applied = try $0.setTransitionLayerCut(id, to: f(25) + Time(1, 100)) }
        #expect(applied == f(25))
        #expect(clip(p, tl, id).transitionLayerCut == f(25))
        #expect(clip(p, tl, id).resolvedTransitionLayer(frameDuration: fd)?.alignment == .custom)
        try p.edit(tl) { applied = try $0.setTransitionLayerCut(id, to: f(5)) }
        #expect(applied == f(20))
        #expect(clip(p, tl, id).resolvedTransitionLayer(frameDuration: fd)?.alignment == .startAtCut)
        try p.edit(tl) { applied = try $0.setTransitionLayerCut(id, to: f(90)) }
        #expect(applied == f(40))
        #expect(clip(p, tl, id).resolvedTransitionLayer(frameDuration: fd)?.alignment == .endAtCut)
        // Not a transition layer.
        let other = p.timeline(tl)!.tracks[0].clips[0].id
        #expect(throws: EditError.clipNotFound) { try p.edit(tl) { _ = try $0.setTransitionLayerCut(other, to: f(3)) } }
    }

    @Test func theCutStaysPutWhenTheClipIsTrimmedOrMoved() throws {
        var (p, tl, _, _, _, _, id) = try stack()
        try p.edit(tl) { _ = try $0.trim(id, edge: .head, by: -f(5)) }      // head out to 15
        #expect(clip(p, tl, id).timeline.start == f(15))
        #expect(clip(p, tl, id).transitionLayerCut == f(30))
        try p.edit(tl) { _ = try $0.trim(id, edge: .head, by: f(8)) }       // head in to 23
        #expect(clip(p, tl, id).transitionLayerCut == f(30))
        // Moving the clip carries its cut along.
        try p.edit(tl) { try $0.move(id, to: f(33)) }
        #expect(clip(p, tl, id).transitionLayerCut == f(40))
    }

    @Test func aCutTrimmedOutsideTheClipResolvesAtTheNearestEdge() throws {
        var (p, tl, _, _, _, _, id) = try stack()
        try p.edit(tl) { _ = try $0.trim(id, edge: .tail, by: -f(15)) }     // 20..<25, stored cut 30
        let r = try #require(clip(p, tl, id).resolvedTransitionLayer(frameDuration: fd))
        #expect(r.cut == f(25) && r.after == .zero && r.before == f(5))
    }

    @Test func symmetricResizeMovesBothEdgesAroundTheCut() throws {
        var (p, tl, _, _, _, _, id) = try stack()
        var moved = Time.zero
        // Drag the head 4 frames left: the tail follows 4 frames right.
        try p.edit(tl) { moved = try $0.resizeTransitionLayer(id, edge: .head, by: -f(4), symmetric: true) }
        #expect(moved == -f(4))
        #expect(clip(p, tl, id).timeline == TimeRange(start: f(16), end: f(44)))
        #expect(clip(p, tl, id).transitionLayerCut == f(30))
        // Drag the tail 6 frames left: the head follows 6 frames right.
        try p.edit(tl) { moved = try $0.resizeTransitionLayer(id, edge: .tail, by: -f(6), symmetric: true) }
        #expect(moved == -f(6))
        #expect(clip(p, tl, id).timeline == TimeRange(start: f(22), end: f(38)))
        // Shrinking stops at the cut on the shorter side.
        try p.edit(tl) { moved = try $0.resizeTransitionLayer(id, edge: .head, by: f(50), symmetric: true) }
        #expect(clip(p, tl, id).timeline == TimeRange(start: f(29), end: f(31)))
        #expect(moved == f(7))
    }

    @Test func symmetricGrowthStopsAtNeighboursOnEitherSide() throws {
        var (p, tl, ids, _, _, _, id) = try stack()
        let blocker = media("X", start: 42, frames: 5)
        try p.edit(tl) { try $0.tracks[2].overwrite(blocker) }
        _ = ids
        var moved = Time.zero
        try p.edit(tl) { moved = try $0.resizeTransitionLayer(id, edge: .head, by: -f(10), symmetric: true) }
        #expect(moved == -f(2))
        #expect(clip(p, tl, id).timeline == TimeRange(start: f(18), end: f(42)))
        // Timeline start limits the other way.
        var (q, tl2, ids2) = project()
        let id2 = try q.addTransitionLayer(kind: .crossDissolve, in: tl2, at: f(3), track: ids2[0], duration: f(10))
        try q.edit(tl2) { moved = try $0.resizeTransitionLayer(id2, edge: .tail, by: f(9), symmetric: true) }
        #expect(moved == f(3))
        #expect(clip(q, tl2, id2).timeline == TimeRange(start: .zero, end: f(16)))
    }

    @Test func freeResizeMovesOneEdgeButNeverPastTheCut() throws {
        var (p, tl, _, _, _, _, id) = try stack()
        var moved = Time.zero
        try p.edit(tl) { moved = try $0.resizeTransitionLayer(id, edge: .tail, by: f(6), symmetric: false) }
        #expect(moved == f(6))
        #expect(clip(p, tl, id).timeline == TimeRange(start: f(20), end: f(46)))
        #expect(clip(p, tl, id).transitionLayerCut == f(30))
        try p.edit(tl) { moved = try $0.resizeTransitionLayer(id, edge: .head, by: f(40), symmetric: false) }
        #expect(moved == f(10))
        #expect(clip(p, tl, id).timeline == TimeRange(start: f(30), end: f(46)))
        try p.edit(tl) { moved = try $0.resizeTransitionLayer(id, edge: .tail, by: -f(40), symmetric: false) }
        // One frame always stays.
        #expect(clip(p, tl, id).timeline == TimeRange(start: f(30), end: f(31)))
        #expect(moved == -f(15))
    }

    @Test func alignmentMovesTheClipAroundAFixedCut() throws {
        var (p, tl, _, _, _, _, id) = try stack()
        try p.edit(tl) { try $0.setTransitionLayerAlignment(id, .startAtCut) }
        #expect(clip(p, tl, id).timeline == TimeRange(start: f(30), end: f(50)))
        #expect(clip(p, tl, id).transitionLayerCut == f(30))
        try p.edit(tl) { try $0.setTransitionLayerAlignment(id, .endAtCut) }
        #expect(clip(p, tl, id).timeline == TimeRange(start: f(10), end: f(30)))
        try p.edit(tl) { try $0.setTransitionLayerAlignment(id, .center) }
        #expect(clip(p, tl, id).timeline == TimeRange(start: f(20), end: f(40)))
        #expect(clip(p, tl, id).transitionLayerCut == f(30))
    }

    @Test func durationKeepsTheCutAndTheSplit() throws {
        var (p, tl, _, _, _, _, id) = try stack()
        try p.edit(tl) { _ = try $0.setTransitionLayerCut(id, to: f(25)) }   // 5 before, 15 after
        try p.edit(tl) { try $0.setTransitionLayerDuration(id, f(40)) }
        #expect(clip(p, tl, id).timeline == TimeRange(start: f(15), end: f(55)))
        #expect(clip(p, tl, id).transitionLayerCut == f(25))
    }

    @Test func styleEditsChangeOnlyTheStyle() throws {
        var (p, tl, _, _, _, _, id) = try stack()
        try p.edit(tl) {
            try $0.setTransitionLayer(id) { s in s.kind = .push; s.direction = .up; s.motionBlur = 1 }
        }
        let c = clip(p, tl, id)
        #expect(c.transitionLayer?.kind == .push && c.transitionLayer?.direction == .up)
        #expect(c.timeline == TimeRange(start: f(20), end: f(40)) && c.transitionLayerCut == f(30))
        #expect(throws: EditError.wrongTrackKind) { try p.edit(tl) { try $0.setTransitionLayer(id) { $0.kind = .stinger } } }
    }

    // MARK: Evaluation

    @Test func beforeTheCutTheStackBelowIsLiveOutgoingAndHeldIncoming() throws {
        let (p, tl, _, a, b, broll, id) = try stack()
        let t = f(24)
        let layers = p.timeline(tl)!.videoLayers(at: t)
        let first = layers.filter { $0.stackTransitions.first?.role == .first }
        let second = layers.filter { $0.stackTransitions.first?.role == .second }
        #expect(first.map(\.clip) == [a.id, broll.id])
        #expect(second.map(\.clip) == [b.id, broll.id])
        #expect(first.first?.sourceTime == f(24))                       // A live
        #expect(second.first?.sourceTime == f(100))                     // B held at its first frame (the cut)
        #expect(second.last?.sourceTime == f(30))                       // b-roll held at the cut
        #expect(layers.allSatisfy { $0.stackTransitions.first?.id == id && $0.inTransition })
        #expect(layers.count == 4)
    }

    @Test func fromTheCutTheOutgoingSideHoldsItsLastFrameAndIncomingPlays() throws {
        let (p, tl, _, a, b, broll, _) = try stack()
        let layers = p.timeline(tl)!.videoLayers(at: f(33))
        let first = layers.filter { $0.stackTransitions.first?.role == .first }
        let second = layers.filter { $0.stackTransitions.first?.role == .second }
        #expect(first.map(\.clip) == [a.id, broll.id])
        #expect(first.first?.sourceTime == f(29))
        #expect(second.map(\.clip) == [b.id, broll.id])
        #expect(second.first?.sourceTime == f(103))
    }

    @Test func dissolveWeightsFollowTheSpanLikeACutTransition() throws {
        let (p, tl, _, _, _, _, _) = try stack()
        let layers = p.timeline(tl)!.videoLayers(at: f(20))
        let tag = try #require(layers.first?.stackTransitions.first)
        let w = TransitionMix.videoWeight(frameIndex: 0, frames: 20)
        #expect(tag.render.compose == .sum)
        #expect(abs(tag.render.outgoing.opacity - (1 - w)) < 1e-9 && abs(tag.render.incoming.opacity - w) < 1e-9)
        #expect(tag.format == p.timeline(tl)!.format && tag.depth == 0)
        // Layer opacities are not touched: the sides are composited whole, then mixed.
        #expect(layers.allSatisfy { $0.transform.opacity == 1 })
    }

    @Test func motionKindsUseTheSharedTransitionRender() throws {
        let (p, tl, _, _, _, _, _) = try stack(kind: .push)
        let layers = p.timeline(tl)!.videoLayers(at: f(25))
        let tag = try #require(layers.first?.stackTransitions.first)
        let expected = TransitionRender.evaluate(kind: .push, direction: .left, softness: TransitionKind.defaultSoftness,
                                                 motionBlur: TransitionKind.push.defaultMotionBlur, easing: TransitionKind.push.defaultEasing,
                                                 frameIndex: 5, frames: 20)
        #expect(tag.render == expected)
    }

    @Test func dipsDrawTheDipColourUnderTheTransition() throws {
        let (p, tl, _, _, _, _, id) = try stack(kind: .dipToWhite)
        let layers = p.timeline(tl)!.videoLayers(at: f(22))
        #expect(layers.first?.generator == GeneratorRef.solid(rgb: [255, 255, 255]))
        #expect(layers.first?.stackTransitions.isEmpty == true)
        #expect(layers.first?.clip == id)
        let tag = try #require(layers.last?.stackTransitions.first)
        let w = TransitionMix.videoWeight(frameIndex: 2, frames: 20)
        let m = TransitionMix.video(.dipToWhite, weight: w)
        #expect(tag.render.compose == .sum)
        #expect(abs(tag.render.outgoing.opacity - m.outgoing) < 1e-9 && abs(tag.render.incoming.opacity - m.incoming) < 1e-9)
    }

    @Test func tracksAboveTheLayerAndTimesOutsideItAreUntouched() throws {
        var (p, tl, _, a, _, broll, _) = try stack()
        let title = media("Title", start: 0, frames: 60)
        try p.edit(tl) { try $0.tracks[3].overwrite(title) }
        let layers = p.timeline(tl)!.videoLayers(at: f(25))
        #expect(layers.last?.clip == title.id && layers.last?.stackTransitions.isEmpty == true)
        #expect(layers.last?.inTransition == false)
        // Outside the span: the plain stack, no tags, and the layer itself draws nothing.
        let before = p.timeline(tl)!.videoLayers(at: f(10))
        #expect(before.map(\.clip) == [a.id, broll.id, title.id])
        #expect(before.allSatisfy { $0.stackTransitions.isEmpty })
    }

    @Test func aHiddenTrackOrDisabledLayerDoesNothing() throws {
        var (p, tl, _, a, _, broll, id) = try stack()
        try p.edit(tl) { $0.tracks[2].isVisible = false }
        #expect(p.timeline(tl)!.videoLayers(at: f(25)).map(\.clip) == [a.id, broll.id])
        try p.edit(tl) { $0.tracks[2].isVisible = true }
        var c = clip(p, tl, id); c.isEnabled = false
        try p.edit(tl) { try $0.replaceClip(c) }
        #expect(p.timeline(tl)!.videoLayers(at: f(25)).map(\.clip) == [a.id, broll.id])
    }

    @Test func aLowerCutTransitionKeepsItsOwnPairInsideTheSide() throws {
        var (p, tl, ids, a, b, _, _) = try stack()
        try p.edit(tl) {
            _ = try $0.addTransition(kind: .crossDissolve, track: ids[0], outgoing: a.id, incoming: b.id, duration: f(4))
        }
        let layers = p.timeline(tl)!.videoLayers(at: f(29))
        // The outgoing side (live at 29) shows the dissolve of A and B; it keeps its pair tag inside the side.
        let first = layers.filter { $0.stackTransitions.first?.role == .first }
        #expect(first.contains { $0.pair != nil })
    }

    @Test func twoStackedLayersNestOuterFirst() throws {
        var (p, tl, ids, _, _, _, inner) = try stack()
        let outer = try p.addTransitionLayer(kind: .crossDissolve, in: tl, at: f(24), track: ids[3], duration: f(4))
        let layers = p.timeline(tl)!.videoLayers(at: f(25))
        #expect(!layers.isEmpty)
        #expect(layers.allSatisfy { $0.stackTransitions.first?.id == outer })
        #expect(layers.allSatisfy { $0.stackTransitions.count == 2 && $0.stackTransitions[1].id == inner })
    }

    @Test func nothingBelowTransitionsToTransparent() throws {
        var (p, tl, ids) = project()
        let a = media("A", start: 0, frames: 30)
        try p.edit(tl) { try $0.tracks[0].overwrite(a) }
        _ = try p.addTransitionLayer(kind: .crossDissolve, in: tl, at: f(20), track: ids[1], duration: f(20))
        let layers = p.timeline(tl)!.videoLayers(at: f(25))
        #expect(layers.map(\.clip) == [a.id])
        #expect(layers.first?.stackTransitions.first?.role == .first)
    }

    // MARK: File

    @Test func aTransitionLayerIsWrittenAsV53AndRoundTrips() throws {
        let (p, tl, _, _, _, _, id) = try stack(kind: .whip)
        #expect(p.containsTransitionLayers)
        #expect(ProjectFile.transitionLayerVersion == 53)
        #expect(ProjectFile.currentVersion >= 53)
        #expect(ProjectFile.writtenVersion(for: p) == ProjectFile.transitionLayerVersion)
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back.timeline(tl)!.tracks.flatMap(\.clips).first { $0.id == id } == clip(p, tl, id))
        let (q, _, _) = project()
        #expect(!q.containsTransitionLayers)
        #expect(ProjectFile.writtenVersion(for: q) < 53)
    }
}
