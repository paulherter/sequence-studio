import AppKit
import CoreGraphics
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

// Transition layer UI (DECISIONS 2026-10-05): drop target on an empty track spot, hit zones, and the session edits.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }
private let geo = TimelineGeometry(frameDuration: fd, pointsPerFrame: 4)

private func clip(_ name: String, start: Int64, frames: Int64 = 60) -> Clip {
    Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(frames)), start: f(start),
         mediaDuration: f(300))
}

/// V1: A 0..60, B 60..120. V2: T 200..260 (a title stand-in). V2 is empty from 0 to 200.
@MainActor private func makeSession() throws -> (EditorSession, Timeline) {
    var v1 = Track(kind: .video), v2 = Track(kind: .video)
    try v1.overwrite(clip("A", start: 0)); try v1.overwrite(clip("B", start: 60))
    try v2.overwrite(clip("T", start: 200))
    let tl = Timeline(name: "T", frameDuration: fd, tracks: [v1, v2])
    let s = EditorSession(project: Project(name: "p", timelines: [tl]))
    s.setSelectionFollowsPlayhead(false)
    return (s, tl)
}

private func point(_ t: Timeline, track: Int, frame: Int64) -> CGPoint {
    let row = geo.rows(for: t).first { $0.track == t.tracks[track].id }!
    return CGPoint(x: geo.x(for: f(frame)), y: row.y + row.height / 2)
}

@Suite struct TransitionLayerUITests {
    @MainActor @Test func dropOnAnEmptySpotCentresOnTheSnappedCutBelow() throws {
        let (_, t) = try makeSession()
        // 1 frame from the A|B cut on V1 (4 pt): snaps onto it.
        let d = try #require(TransitionLayerLayout.dropTarget(at: point(t, track: 1, frame: 61), kind: .crossDissolve, in: t,
                                                              geometry: geo, playhead: f(500), duration: f(20)))
        #expect(d.track == t.tracks[1].id && d.cut == f(60) && d.start == f(50) && d.duration == f(20))
        #expect(abs(d.rect.minX - geo.x(for: f(50))) < 0.01)
    }

    @MainActor @Test func dropSnapsToThePlayheadAndFitsIntoTheGap() throws {
        let (_, t) = try makeSession()
        // Playhead at 195; the gap on V2 ends at 200, so the layer ends there and the cut stays on the playhead.
        let d = try #require(TransitionLayerLayout.dropTarget(at: point(t, track: 1, frame: 196), kind: .crossDissolve, in: t,
                                                              geometry: geo, playhead: f(195), duration: f(20)))
        #expect(d.cut == f(195) && d.start == f(180) && d.duration == f(20))
        // At the timeline start the layer starts at 0.
        let s = try #require(TransitionLayerLayout.dropTarget(at: point(t, track: 1, frame: 3), kind: .crossDissolve, in: t,
                                                              geometry: geo, playhead: f(500), duration: f(20)))
        #expect(s.start == .zero && s.cut == f(3))
    }

    @MainActor @Test func noDropOnAClipNorForNonLayerKinds() throws {
        let (_, t) = try makeSession()
        #expect(TransitionLayerLayout.dropTarget(at: point(t, track: 1, frame: 220), kind: .crossDissolve, in: t,
                                                 geometry: geo, playhead: .zero, duration: f(20)) == nil)
        #expect(TransitionLayerLayout.dropTarget(at: point(t, track: 1, frame: 100), kind: .stinger, in: t,
                                                 geometry: geo, playhead: .zero, duration: f(20)) == nil)
    }

    @MainActor @Test func hitZonesFindTheCutMarkerAndTheEdges() throws {
        let (s, _) = try makeSession()
        let id = try #require(s.addTransitionLayer(kind: .crossDissolve, track: s.activeTimeline!.tracks[1].id,
                                                   start: f(40), duration: f(40), cut: f(60)))
        let t = s.activeTimeline!
        let y = point(t, track: 1, frame: 0).y
        #expect(TransitionLayerLayout.hitTest(CGPoint(x: geo.x(for: f(60)) + 2, y: y), in: t, geometry: geo)?.zone == .cut)
        #expect(TransitionLayerLayout.hitTest(CGPoint(x: geo.x(for: f(40)) + 2, y: y), in: t, geometry: geo)?.zone == .head)
        #expect(TransitionLayerLayout.hitTest(CGPoint(x: geo.x(for: f(80)) - 2, y: y), in: t, geometry: geo)?.zone == .tail)
        #expect(TransitionLayerLayout.hitTest(CGPoint(x: geo.x(for: f(50)), y: y), in: t, geometry: geo) == nil)
        #expect(TransitionLayerLayout.hitTest(CGPoint(x: geo.x(for: f(60)) + 2, y: y), in: t, geometry: geo)?.id == id)
    }

    @MainActor @Test func addIsOneUndoStepAndSelectsTheLayer() throws {
        let (s, _) = try makeSession()
        let id = try #require(s.addTransitionLayer(kind: .crossDissolve, track: s.activeTimeline!.tracks[1].id,
                                                   start: f(180), duration: f(20), cut: f(195)))
        #expect(s.selection == [id])
        #expect(s.activeTimeline!.resolvedTransitionLayer(id)?.cut == f(195))
        #expect(s.undo())
        #expect(!s.activeTimeline!.tracks.contains { $0.clips.contains { $0.id == id } })
    }

    @MainActor @Test func cutDragAndResizeCoalesceIntoOneStepEach() throws {
        let (s, _) = try makeSession()
        let id = try #require(s.addTransitionLayer(kind: .crossDissolve, track: s.activeTimeline!.tracks[1].id,
                                                   start: f(40), duration: f(40), cut: f(60)))
        s.moveTransitionLayerCut(id, to: f(65), continuesGesture: false)
        s.moveTransitionLayerCut(id, to: f(70), continuesGesture: true)
        #expect(s.activeTimeline!.resolvedTransitionLayer(id)?.cut == f(70))
        #expect(s.undo())
        #expect(s.activeTimeline!.resolvedTransitionLayer(id)?.cut == f(60))
        // Symmetric: the tail out by 5 moves the head out by 5.
        let moved = s.resizeTransitionLayer(id, edge: .tail, by: f(5), symmetric: true, continuesGesture: false)
        #expect(moved == f(5))
        _ = s.resizeTransitionLayer(id, edge: .tail, by: f(5), symmetric: true, continuesGesture: true)
        let r = try #require(s.activeTimeline!.resolvedTransitionLayer(id))
        #expect(r.span == TimeRange(start: f(30), duration: f(60)) && r.cut == f(60))
        #expect(s.undo())
        #expect(s.activeTimeline!.resolvedTransitionLayer(id)?.span == TimeRange(start: f(40), duration: f(40)))
    }

    @MainActor @Test func inspectorEditsRouteToTheLayer() throws {
        let (s, _) = try makeSession()
        let id = try #require(s.addTransitionLayer(kind: .crossDissolve, track: s.activeTimeline!.tracks[1].id,
                                                   start: f(40), duration: f(40), cut: f(60)))
        #expect(s.setTransitionLayerKind(id, .dipToBlack))
        #expect(s.setTransitionLayerDuration(id, f(20)))
        #expect(s.setTransitionLayerAlignment(id, .startAtCut))
        #expect(s.setTransitionLayerStyle(id, "Easing", continuesGesture: false) { $0.easing = .easeIn })
        let c = try #require(s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id })
        #expect(c.transitionLayer?.kind == .dipToBlack && c.transitionLayer?.easing == .easeIn)
        let r = try #require(c.resolvedTransitionLayer(frameDuration: fd))
        #expect(r.span == TimeRange(start: f(60), duration: f(20)) && r.alignment == .startAtCut)
        #expect(!s.setTransitionLayerKind(id, .stinger))
        #expect(s.transitionLayerInfo(id)?.transition.kind == .dipToBlack)
    }

    @MainActor @Test func controlsInLayerModeOfferTheTypeAndAllAlignments() throws {
        let (s, _) = try makeSession()
        let id = try #require(s.addTransitionLayer(kind: .crossDissolve, track: s.activeTimeline!.tracks[1].id,
                                                   start: f(40), duration: f(40), cut: f(60)))
        let info = try #require(s.transitionLayerInfo(id))
        let c = TransitionControlsView()
        c.update(transition: info.transition, resolved: info.resolved, frameDuration: fd, isLayer: true)
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let pops = all(c).compactMap { $0 as? NSPopUpButton }
        let kind = try #require(pops.first { $0.accessibilityLabel() == "Transition type" })
        let align = try #require(pops.first { $0.accessibilityLabel() == "Transition alignment" })
        #expect(align.isEnabled && align.numberOfItems == 3 && kind.titleOfSelectedItem == TransitionKind.crossDissolve.name)
        var picked: TransitionKind?
        c.onKind = { picked = $0 }
        kind.selectItem(withTitle: TransitionKind.dipToWhite.name)
        kind.sendAction(kind.action, to: kind.target)
        #expect(picked == .dipToWhite)
        #expect(!(0..<kind.numberOfItems).contains { kind.item(at: $0)?.title == TransitionKind.stinger.name })
    }
}
