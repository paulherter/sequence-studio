import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }
private func clip(_ name: String, start: Int64) -> Clip {
    Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(60)), start: f(start), mediaDuration: f(300))
}

/// Transition "Custom" easing: the curve popover edits the stored curve of a clip-edge transition or a transition layer.
@MainActor @Suite struct TransitionCustomCurveUITests {
    private static let drawn = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.2, dy: 0.9), in: EaseHandle(dx: 0.7, dy: 0.1))

    private func make() throws -> (EditorSession, Transition.ID, Clip.ID) {
        var v1 = Track(kind: .video), v2 = Track(kind: .video)
        let a = clip("A", start: 0), b = clip("B", start: 60)
        try v1.overwrite(a); try v1.overwrite(b)
        try v2.overwrite(clip("T", start: 200))
        var tl = Timeline(name: "T", frameDuration: fd, tracks: [v1, v2])
        let tid = try tl.addTransition(kind: .crossDissolve, track: v1.id, outgoing: a.id, incoming: b.id, duration: f(12))
        let s = EditorSession(project: Project(name: "p", timelines: [tl]))
        s.setSelectionFollowsPlayhead(false)
        let layer = try #require(s.addTransitionLayer(kind: .crossDissolve, track: s.activeTimeline!.tracks[1].id,
                                                      start: f(40), duration: f(40), cut: f(60)))
        return (s, tid, layer)
    }

    @Test func popupIndexIsPresetOrCustom() throws {
        #expect(TransitionControlsView.easingIndex(of: .easeOut) == TransitionControlsView.easings.firstIndex(of: .easeOut))
        let c = try #require(EasingCurve.transitionCustom(Self.drawn))
        #expect(TransitionControlsView.easingIndex(of: c) == TransitionControlsView.customEasingIndex)
    }

    @Test func edgeSourceWritesDrawnCurveInOneUndoStep() throws {
        let (s, tid, _) = try make()
        let src = TransitionEaseSource(session: s, target: .edge(tid))
        #expect(src.easeReading == .common(EasingCurve.linear.shape))
        src.beginGesture()
        src.applyEaseShape(EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.1, dy: 0.2), in: EaseHandle(dx: 0.5, dy: 0.5)))
        src.applyEaseShape(Self.drawn)
        src.endGesture()
        #expect(src.easeReading == .common(Self.drawn))
        #expect(s.transitionInfo(tid)?.transition.easing?.shape == Self.drawn)
        #expect(s.undo())
        #expect(s.transitionInfo(tid)?.transition.easing == nil)   // the whole drag was one step
        src.applyEaseShape(.hold)                                   // hold is refused
        #expect(s.transitionInfo(tid)?.transition.easing == nil)
    }

    /// Feedback 2026-10-06: Easing > Custom is the speed curve of the keyframe rows (not a value graph) and its handles drag.
    @Test func customPopoverIsTheSpeedCurveAndItsHandlesDrag() throws {
        let (s, tid, _) = try make()
        s.setTransitionStyle(tid, easing: .easeInOut)
        let c = EasingCurvePopoverController(source: TransitionEaseSource(session: s, target: .edge(tid)),
                                             library: EasingPresetLibrary(store: nil))
        c.loadView(); c.refresh()
        let e: EaseSpeedEditorView = c.editor
        #expect(e.superview === c.view)
        // A transition refuses Hold (it would be a cut): no Hold chip, the other built-ins stay.
        #expect(!c.chipItemsForTests.contains { $0.name == "Hold" })
        #expect(c.chipItemsForTests.map(\.name) == EasingCurve.builtIns.filter { $0.interpolation != .hold }.map(\.displayName))
        #expect(e.reading == .common(EasingCurve.easeInOut.shape))
        let geo = e.geometry, seg = try #require(e.segment)
        // The same geometry as the keyframe row's graph: a hill from the baseline, handles level with their keys.
        let out = geo.handleEnd(seg, side: .out), inn = geo.handleEnd(seg, side: .in)
        #expect(out.y == geo.baseline && inn.y == geo.baseline && out.x < inn.x)
        #expect(abs((out.x - geo.key(seg, side: .out).x) - geo.width(seg) / 2 / 3) < 1e-6)     // 33 % of the way to the middle
        #expect(e.handle(at: out) == .out && e.handle(at: inn) == .in)
        #expect(!e.press(at: CGPoint(x: e.bounds.midX, y: 4)))                                  // empty space grabs nothing
        // Drag the left handle sideways to the middle: 100 %, one undo step, speed at the key unchanged.
        #expect(e.press(at: out))
        e.dragGesture(to: CGPoint(x: out.x + 20, y: out.y - 3))
        e.dragGesture(to: CGPoint(x: geo.x(seg, share: 0.5) + 40, y: out.y + 2))
        e.release()
        let stored = try #require(s.transitionInfo(tid)?.transition.easing?.shape)
        #expect(stored.reachOut == 1 && stored.speedOut == 0)
        #expect(abs(stored.reachIn - 1.0 / 3) < 1e-9 && stored.speedIn == 0)
        c.refresh()
        #expect(e.reading == .common(stored))
        #expect(abs(e.geometry.handleEnd(try #require(e.segment), side: .out).x - geo.x(seg, share: 0.5)) < 1e-6)
        #expect(s.undo())
        #expect(s.transitionInfo(tid)?.transition.easing == .easeInOut)
    }

    @Test func easingPopUpUsesTheKeyframeNames() {
        let v = TransitionControlsView()
        #expect(v.easingTitlesForTests == ["Steady", "Smooth", "Smooth In", "Smooth Out", "Fast Start", "Fast End",
                                             "Smooth In 100%", "Smooth Out 100%", "Overshoot", "Custom\u{2026}"])
    }

    @Test func layerSourceWritesDrawnCurve() throws {
        let (s, _, layer) = try make()
        let src = TransitionEaseSource(session: s, target: .layer(layer))
        src.applyEaseShape(Self.drawn)
        let l = try #require(s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == layer }?.transitionLayer)
        #expect(l.easing?.shape == Self.drawn)
        #expect(src.easeReading == .common(Self.drawn))
        // A preset chip stores the named preset.
        src.applyEaseShape(EasingCurve.fastStart.shape)
        #expect(s.transitionLayerInfo(layer)?.transition.easing == .fastStart)
    }
}
