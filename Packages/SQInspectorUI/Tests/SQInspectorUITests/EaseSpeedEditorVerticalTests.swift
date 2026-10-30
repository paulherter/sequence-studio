import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

/// The curve editor's handles drag up and down too: the speed at the key, below 0 for wind-up and overshoot
/// (coordinator 2026-10-06: settle and overshoot must stay possible by hand in the one editor).
@MainActor @Suite struct EaseSpeedEditorVerticalTests {
    private func editor(_ shape: EaseShape) -> (EaseSpeedEditorView, Box) {
        let e = EaseSpeedEditorView(frame: NSRect(x: 0, y: 0, width: 260, height: 126)), box = Box()
        e.reading = .common(shape)
        e.onBegin = { box.begins += 1 }
        e.onChange = { box.shapes.append($0); e.reading = .common($0) }
        e.onEnd = { box.ends += 1 }
        return (e, box)
    }
    final class Box { var shapes: [EaseShape] = []; var begins = 0; var ends = 0 }

    @Test func geometryMakesRoomBelowZeroOnlyWhenAsked() {
        let lane = KeyframeLaneGeometry(width: 260, duration: Time(1, 1), inset: 18)
        var g = SpeedGraphGeometry(lane: lane, height: 126, peak: 1.5)
        #expect(g.baseline == 126 - SpeedGraphGeometry.baselineInset && g.unitHeight == SpeedGraphGeometry.unit)   // as before
        #expect(abs(g.speed(atY: g.baseline - g.unitHeight) - 1) < 1e-9 && g.speed(atY: g.baseline) == 0)
        g.low = -1
        #expect(g.baseline < 126 - SpeedGraphGeometry.baselineInset)
        #expect(abs(g.y(speed: -1) - (126 - SpeedGraphGeometry.baselineInset)) < 1e-6)       // -1x sits where 0 used to
        #expect(g.y(speed: 1.5) >= SpeedGraphGeometry.topInset - 1e-6)
        #expect(abs(g.speed(atY: g.y(speed: -0.7)) - -0.7) < 1e-9)
        let seg = EaseTrackSegment(from: UUID(), to: UUID(), start: .zero, end: Time(1, 1),
                                   shape: EasingCurve.easeInOut.shape.settingSpeed(-1.2, side: .in))
        #expect(abs(SpeedGraphGeometry.low(of: [seg]) - -1.2) < 1e-9)
        #expect(SpeedGraphGeometry.low(of: [EaseTrackSegment(from: UUID(), to: UUID(), start: .zero, end: Time(1, 1), shape: .linear)]) == 0)
    }

    @Test func draggingAHandleUpSetsTheSpeedAtItsKeyAndKeepsTheReach() throws {
        let (e, box) = editor(EasingCurve.easeInOut.shape)
        let geo = e.geometry, seg = try #require(e.segment)
        let out = geo.handleEnd(seg, side: .out)
        #expect(e.press(at: out))
        e.dragGesture(to: CGPoint(x: out.x, y: out.y - 3))                  // inside the slop: nothing vertical yet
        #expect(box.shapes.last?.speedOut == 0)
        e.dragGesture(to: CGPoint(x: out.x, y: out.y - geo.unitHeight))     // one unit up: steady speed at the key
        let s = try #require(box.shapes.last)
        #expect(abs(s.speedOut - 1) < 1e-9 && abs(s.reachOut - 1.0 / 3) < 1e-9)
        #expect(s.in == EasingCurve.easeInOut.shape.in)
        // The scale holds still during the drag: the knob is under the pointer.
        #expect(abs(e.geometry.handleEnd(try #require(e.segment), side: .out).y - (out.y - geo.unitHeight)) < 1e-6)
        e.release()
        #expect(box.begins == 1 && box.ends == 1)
        #expect(e.readout == nil)
    }

    @Test func draggingTheRightHandleBelowZeroOvershootsAndTheReadoutSaysSo() throws {
        let (e, box) = editor(EasingCurve.easeInOut.shape)
        let geo = e.geometry, seg = try #require(e.segment)
        let inn = geo.handleEnd(seg, side: .in)
        #expect(e.press(at: inn))
        e.dragGesture(to: CGPoint(x: inn.x, y: inn.y + 60))                 // below the view's 0 line
        e.release()
        let s = try #require(box.shapes.last)
        #expect(abs(s.speedIn - -60 / Double(geo.unitHeight)) < 1e-9 && abs(s.reachIn - 1.0 / 3) < 1e-9)
        #expect(s.valueExcursion.above > 0.02)
        #expect(e.readout?.hasPrefix("Overshoot ") == true && e.readout?.hasSuffix("%") == true)
        // After the drag the plot makes room below 0 and the handle can be grabbed again where it is drawn.
        let after = e.geometry, seg2 = try #require(e.segment)
        #expect(after.baseline < geo.baseline)
        let knob = after.handleEnd(seg2, side: .in)
        #expect(knob.y > after.baseline && knob.y <= e.bounds.maxY && e.handle(at: knob) == .in)
        // Left handle below zero: wind-up.
        let o = after.handleEnd(seg2, side: .out)
        #expect(e.press(at: o))
        e.dragGesture(to: CGPoint(x: o.x, y: o.y + 30))
        e.release()
        #expect(e.readout?.contains("Wind-Up ") == true && e.readout?.contains("Overshoot ") == true)
    }

    @Test func theVerticalDragStopsAtWhatTheSourceCanStore() throws {
        let (e, box) = editor(EasingCurve.easeInOut.shape)
        e.valueRange = 0...1                                                // a speed transition of the band
        let seg = try #require(e.segment), inn = e.geometry.handleEnd(seg, side: .in)
        #expect(e.press(at: inn))
        e.dragGesture(to: CGPoint(x: inn.x, y: inn.y + 80))
        e.dragGesture(to: CGPoint(x: inn.x, y: inn.y - 4000))
        e.release()
        #expect(box.shapes.dropLast().last?.in.dy == 0 && box.shapes.last?.in.dy == 1)
        #expect(e.readout == nil)
    }

    /// Sideways, a longer handle at the same speed gets a bigger value part: it stops at what the source stores, during
    /// the drag, so nothing jumps when it is written.
    @Test func theSidewaysDragKeepsTheValueInsideTheRangeToo() throws {
        let steep = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.2, dy: 0.6), in: EaseHandle(dx: 1.0 / 3, dy: 0))
        for (range, top) in [(0.0...1.0, 1.0), (-2.0...3.0, 3.0)] {
            let (e, box) = editor(steep)
            e.valueRange = range
            let geo = e.geometry, seg = try #require(e.segment), out = geo.handleEnd(seg, side: .out)
            #expect(e.press(at: out))
            e.dragGesture(to: CGPoint(x: geo.x(seg, share: 0.5) + 30, y: out.y))        // reach 1 at speed 3: dy would be 3
            e.release()
            let s = try #require(box.shapes.last)
            #expect(s.reachOut == 1 && abs(s.out.dy - top) < 1e-9)
            #expect(box.shapes.allSatisfy { range.contains($0.out.dy) })
        }
    }

    /// Selected segments with different curves: straight handles over the ghosts, a drag writes one curve to all.
    @Test func aMixedSelectionShowsHandlesAndADragWritesOneCurveToAll() throws {
        let m = EffectControlsModel()
        var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        clip.animation.position.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(0, 0)), Keyframe(time: Time(2, 1), value: Vec2(100, 0))])
        clip.animation.scale.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(1, 1)), Keyframe(time: Time(2, 1), value: Vec2(2, 2))])
        var edits: [Bool] = []
        m.onEdit = { n, _, coalescing in edits.append(coalescing); m.setClip(n) }
        m.setClip(clip)
        for k in clip.animation.scale.track.keys { m.selectKey(.scale, id: k.id, extend: true) }
        m.applyEaseShape(EasingCurve.easeInOut.shape)
        for k in clip.animation.position.track.keys { m.selectKey(.position, id: k.id, extend: true) }
        guard case .mixed = m.easeReading else { Issue.record("expected mixed"); return }
        edits.removeAll()
        let c = EasingCurvePopoverController(model: m, library: EasingPresetLibrary(store: nil))
        c.loadView(); c.refresh()
        let e = c.editor
        #expect(e.shownShape == .linear && e.readout == nil)
        let seg = try #require(e.segment), geo = e.geometry
        let out = geo.handleEnd(seg, side: .out)
        #expect(e.handle(at: out) == .out && e.handle(at: geo.handleEnd(seg, side: .in)) == .in)
        #expect(e.press(at: out))
        e.dragGesture(to: CGPoint(x: out.x + 20, y: out.y))
        e.dragGesture(to: CGPoint(x: geo.x(seg, share: 0.5), y: out.y))
        e.release()
        let a = m.clip!.animation
        #expect(a.position.track.keys[0].outHandle == a.scale.track.keys[0].outHandle)
        #expect(a.position.track.keys[1].inHandle == a.scale.track.keys[1].inHandle)
        #expect(a.position.track.keys[0].outHandle.dx == 1)
        #expect(edits.first == false && edits.dropFirst().allSatisfy { $0 })     // one undo step
        c.refresh()
        if case .common = e.reading {} else { Issue.record("one curve on all after the drag") }
    }

    /// A curve with overshoot saved before (free handles of the old value editor) opens, shows and stays as it is.
    @Test func aSavedOvershootCurveRoundTripsUnchanged() throws {
        let old = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.2, dy: 0.9), in: EaseHandle(dx: 0.3, dy: -0.4))
        // Transition custom curve.
        var v1 = Track(kind: .video)
        let a = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(60)), start: f(0), mediaDuration: f(300))
        let b = Clip(name: "B", media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(60)), start: f(60), mediaDuration: f(300))
        try v1.overwrite(a); try v1.overwrite(b)
        var tl = Timeline(name: "T", frameDuration: fd, tracks: [v1])
        let tid = try tl.addTransition(kind: .crossDissolve, track: v1.id, outgoing: a.id, incoming: b.id, duration: f(12))
        let s = EditorSession(project: Project(name: "p", timelines: [tl]))
        let src = TransitionEaseSource(session: s, target: .edge(tid))
        src.applyEaseShape(old)
        let stored = try #require(s.transitionInfo(tid)?.transition.easing)
        #expect(stored.shape == old)
        let c = EasingCurvePopoverController(source: src, library: EasingPresetLibrary(store: nil))
        c.loadView(); c.refresh()
        let e = c.editor
        #expect(e.reading == .common(old))
        #expect(e.readout?.contains("Overshoot") == true)
        // Grabbing a handle and letting go, or dragging it back to where it was, changes nothing.
        let seg = try #require(e.segment)
        for side in [EaseSide.out, .in] {
            let p = e.geometry.handleEnd(seg, side: side)
            #expect(e.press(at: p))
            e.release()
            #expect(e.press(at: p))
            e.dragGesture(to: CGPoint(x: p.x + 25, y: p.y + 25))
            e.dragGesture(to: p)
            e.release()
            c.refresh()
        }
        let now = try #require(s.transitionInfo(tid)?.transition.easing?.shape)
        #expect(now.isApproximatelyEqual(to: old, tolerance: 1e-9))
        // Keyframes: the same curve on a segment reads back exactly.
        let m = EffectControlsModel()
        var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        clip.animation.position.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(0, 0)), Keyframe(time: Time(2, 1), value: Vec2(100, 0))])
        m.onEdit = { n, _, _ in m.setClip(n) }
        m.setClip(clip)
        for k in clip.animation.position.track.keys { m.selectKey(.position, id: k.id, extend: true) }
        m.applyEaseShape(old)
        let kc = EasingCurvePopoverController(model: m, library: EasingPresetLibrary(store: nil))
        kc.loadView(); kc.refresh()
        #expect(kc.editor.reading == .common(old))
        #expect(m.clip!.animation.position.track.keys[0].outHandle == old.out && m.clip!.animation.position.track.keys[1].inHandle == old.in)
    }
}
