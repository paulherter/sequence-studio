import CoreGraphics
import Foundation
import SQCore
import Testing
@testable import SQInspectorUI

/// Graph Editor (AE style, speed only): one shared plot, curves of the selected property rows, multi-select, group move,
/// shared handle edits, snap, fit, ease buttons.
@MainActor @Suite struct GraphEditorTests {
    let o0 = UUID(), o1 = UUID(), p0 = UUID(), p1 = UUID()

    /// 10 s clip at 0; Opacity 0 -> 100 % over 0...4 s, Position (0,0) -> (300,400) over 2...6 s (500 px).
    func makeModel(showAll: Bool = true) -> (EffectControlsModel, Log) {
        var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        clip.animation.opacity.track = KeyframeTrack(keys: [Keyframe(id: o0, time: Time(0, 1), value: 0),
                                                            Keyframe(id: o1, time: Time(4, 1), value: 1)])
        clip.animation.position.track = KeyframeTrack(keys: [Keyframe(id: p0, time: Time(2, 1), value: Vec2(0, 0)),
                                                             Keyframe(id: p1, time: Time(6, 1), value: Vec2(300, 400))])
        let m = EffectControlsModel()
        let log = Log()
        m.onEdit = { c, name, coalescing in log.edits.append((name, coalescing)); _ = c }
        m.setClip(clip)
        m.graphShowAll = showAll
        return (m, log)
    }
    final class Log { var edits: [(String, Bool)] = [] }

    func member(_ p: EffectProperty, _ id: UUID) -> SummaryMember { SummaryMember(property: p.id, keyID: id) }

    func geometry(_ m: EffectControlsModel) -> GraphEditorGeometry {
        GraphEditorGeometry(lane: m.laneGeometry(width: 520), height: 240, curves: m.graphEditorCurves())
    }

    @Test func showAllOverlaysEveryAnimatedPropertyWithItsOwnColour() {
        let (m, _) = makeModel()
        let curves = m.graphEditorCurves()
        #expect(curves.map(\.property) == [EffectProperty.position.id, EffectProperty.opacity.id])
        #expect(curves.map(\.colorIndex) == [0, 3])
        #expect(m.graphColorSlot(.opacity) == 3 && m.graphColorSlot(.rotation) == nil)
    }

    @Test func selectedRowsDecideWhatIsDrawn() {
        let (m, _) = makeModel(showAll: false)
        #expect(m.graphEditorCurves().isEmpty)
        m.selectGraphProperty(.opacity, extend: false)
        #expect(m.graphEditorCurves().map(\.property) == [EffectProperty.opacity.id])
        // Shift / Cmd adds; a row without motion draws a flat line (no keys).
        m.selectGraphProperty(.rotation, extend: true)
        let curves = m.graphEditorCurves()
        #expect(curves.map(\.property) == [EffectProperty.rotation.id, EffectProperty.opacity.id])
        #expect(curves.first?.curve.keys.isEmpty == true)
        // Extend-clicking a selected row removes it; a plain click replaces.
        m.selectGraphProperty(.rotation, extend: true)
        #expect(m.graphProperties == [.opacity])
        m.selectGraphProperty(.position, extend: false)
        #expect(m.graphProperties == [.position])
        // A selected key's property is drawn too.
        m.select([member(.opacity, o0)], extend: false)
        #expect(Set(m.graphEditorCurves().map(\.property)) == [EffectProperty.position.id, EffectProperty.opacity.id])
    }

    @Test func allCurvesShareOneRelativeSpeedAxisWithZeroAtTheBottom() {
        let (m, _) = makeModel()
        let g = geometry(m)
        #expect(g.range == 0...GraphEditorGeometry.minTop)
        #expect(abs(g.y(speed: 0) - g.plotBottom) < 1e-9)
        // Steady on both (125 px/s and 25 %/s): the same flat line at 1x, whatever the units.
        let pos = g.curve(EffectProperty.position.id)!, op = g.curve(EffectProperty.opacity.id)!
        #expect(abs(g.keyPoint(pos, pos.curve.keys[0]).y - g.y(speed: 1)) < 1e-6)
        #expect(abs(g.keyPoint(op, op.curve.keys[0]).y - g.y(speed: 1)) < 1e-6)
        let ticks = g.speedTicks()
        #expect(ticks.contains(1) && ticks.allSatisfy { $0 > 0 && $0 <= g.range.upperBound })
        // The axis grows (never shrinks) while a drag runs.
        var tall = g; tall.range = 0...4
        #expect(g.growing(from: tall).range.upperBound == 4 && tall.growing(from: g).range.upperBound == 4)
    }

    @Test func hoverReportsPropertyAndRealSpeed() {
        let (m, _) = makeModel()
        let g = geometry(m)
        let x = g.lane.x(seconds: 5)
        let hit = g.hover(at: CGPoint(x: x, y: g.y(speed: 1)))
        #expect(hit?.property == EffectProperty.position.id)
        #expect(abs((hit?.speed ?? 0) - 125) < 1e-6)                 // px/s
        let op = g.hover(at: CGPoint(x: g.lane.x(seconds: 1), y: g.y(speed: 1)))
        #expect(op?.property == EffectProperty.opacity.id && abs((op?.speed ?? 0) - 25) < 1e-6)     // %/s
        #expect(g.hover(at: CGPoint(x: x, y: g.plotTop)) == nil)
    }

    @Test func clickOnStackedKeysSelectsTheWholeStack() {
        let (m, _) = makeModel()
        let s0 = UUID(), s1 = UUID()
        var c = m.clip!
        c.animation.scale.track = KeyframeTrack(keys: [Keyframe(id: s0, time: Time(0, 1), value: Vec2(1, 1)),
                                                       Keyframe(id: s1, time: Time(4, 1), value: Vec2(2, 2))])
        m.setClip(c)
        let g = geometry(m)
        let op = g.curve(EffectProperty.opacity.id)!
        let click = GraphEditorGesture(at: g.keyPoint(op, op.curve.keys[0]), shift: false, geometry: g, selection: [])
        #expect(click.endSelection() == [member(.opacity, o0), member(.scale, s0)])
    }

    @Test func snapPullsTheMoveOntoPlayheadAndOtherKeys() {
        // Moving keys at 2 s by 0.95 s with a key at 3 s nearby snaps to exactly 1 s.
        #expect(abs(GraphEditorSnap.delta(0.95, moving: [2], targets: [3], tolerance: 0.1) - 1) < 1e-12)
        #expect(GraphEditorSnap.delta(0.5, moving: [2], targets: [3], tolerance: 0.1) == 0.5)
        let (m, _) = makeModel()
        m.graphSnap = true
        m.select([member(.opacity, o1)], extend: false)
        m.beginGesture()
        m.moveGraphSelection(bySeconds: 1.9, snapTolerance: 0.2)     // 5.9 s snaps onto the Position key at 6 s
        m.endGraphKeyMove()
        #expect(m.clip!.animation.opacity.track.key(id: o1)?.time == Time(6, 1))
    }

    @Test func fitZoomsToAllKeysOrTheSelection() {
        let (m, _) = makeModel()
        m.fitGraph(selectionOnly: false)
        #expect(m.viewport.start <= 1e-9 && m.viewport.end >= 6 && m.viewport.end < 7)
        m.select([member(.position, p0), member(.position, p1)], extend: false)
        m.fitGraph(selectionOnly: true)
        #expect(m.viewport.start > 1.5 && m.viewport.start < 2 && m.viewport.end > 6 && m.viewport.end < 6.5)
    }

    @Test func graphShortcutsResolveAndAct() {
        #expect(GraphEditorShortcut.resolve(keyCode: 3, characters: "f", flags: []) == .fitAll)
        #expect(GraphEditorShortcut.resolve(keyCode: 3, characters: "F", flags: [.shift]) == .fitSelection)
        #expect(GraphEditorShortcut.resolve(keyCode: 0, characters: "a", flags: [.command]) == .selectAll)
        #expect(GraphEditorShortcut.resolve(keyCode: 101, characters: nil, flags: []) == .ease(.easyEase))
        #expect(GraphEditorShortcut.resolve(keyCode: 101, characters: nil, flags: [.shift]) == .ease(.easeIn))
        #expect(GraphEditorShortcut.resolve(keyCode: 101, characters: nil, flags: [.command, .shift]) == .ease(.easeOut))
        #expect(GraphEditorShortcut.resolve(keyCode: 3, characters: "f", flags: [.command]) == nil)
        let (m, _) = makeModel()
        m.perform(.selectAll)
        #expect(m.selection.count == m.graphEditorCurves().map { $0.curve.keys.count }.reduce(0, +))
        #expect(!m.selection.isEmpty)
    }

    @Test func easeButtonsActOnTheSelection() {
        let (m, _) = makeModel()
        m.select([member(.opacity, o0)], extend: false)
        m.applyGraphEase(.hold)
        #expect(m.clip!.animation.opacity.track.key(id: o0)?.interpolation == .hold)
    }

    @Test func marqueeSelectsKeysOfSeveralProperties() {
        let (m, _) = makeModel()
        let g = geometry(m)
        var gesture = GraphEditorGesture(at: CGPoint(x: 1, y: 1), shift: false, geometry: g, selection: [])
        let x2 = g.lane.x(seconds: 2.5)
        let a = gesture.drag(to: CGPoint(x: x2, y: 239))
        #expect(a == .select([member(.opacity, o0), member(.position, p0)], marquee: CGRect(x: 1, y: 1, width: x2 - 1, height: 238)))
    }

    @Test func draggingOneSelectedKeyMovesTheWholeSelectionAsOneUndoStep() {
        let (m, log) = makeModel()
        m.graphSnap = false
        m.select([member(.opacity, o1), member(.position, p1)], extend: false)
        let g = geometry(m)
        let c = g.curve(EffectProperty.opacity.id)!
        let start = g.keyPoint(c, c.curve.keys[1])
        var gesture = GraphEditorGesture(at: start, shift: false, geometry: g, selection: m.selection)
        #expect(gesture.kind == .keys)
        m.beginGesture()
        let left = g.lane.pointsPerSecond * 1
        guard case .moveKeys(let secs) = gesture.drag(to: CGPoint(x: start.x - left, y: start.y)) else { Issue.record("move"); return }
        m.moveGraphSelection(bySeconds: secs)
        m.endGraphKeyMove()
        #expect(m.clip!.animation.opacity.track.key(id: o1)?.time == Time(3, 1))
        #expect(m.clip!.animation.position.track.key(id: p1)?.time == Time(5, 1))
        #expect(m.selection == [member(.opacity, o1), member(.position, p1)])
        #expect(log.edits.count == 1)
    }

    @Test func handleDragEasesEverySelectedKeyTogether() {
        let (m, log) = makeModel()
        m.select([member(.opacity, o0), member(.position, p0)], extend: false)
        let g = geometry(m)
        let c = g.curve(EffectProperty.position.id)!
        let h = c.curve.handles.first { $0.keyID == p0 && $0.side == .outgoing }!
        let hp = g.handlePoint(c, h)!
        var gesture = GraphEditorGesture(at: hp, shift: false, geometry: g, selection: m.selection)
        #expect(gesture.kind == .handle(member(.position, p0), .outgoing))
        m.beginGesture()
        // Straight down to speed 0 (Smooth out): the handle follows the pointer 1:1, the influence stays.
        let action = gesture.drag(to: CGPoint(x: hp.x, y: g.y(speed: 0)))
        guard case .setHandle(let handle, let side) = action else { Issue.record("handle"); return }
        #expect(side == .outgoing && abs(handle.dy) < 1e-6 && abs(handle.dx - 1.0 / 3) < 1e-6)
        m.setGraphHandle(handle, side: side)
        m.endGesture()
        #expect(m.clip!.animation.opacity.track.key(id: o0)?.outHandle == handle)
        #expect(m.clip!.animation.position.track.key(id: p0)?.outHandle == handle)
        #expect(m.clip!.animation.position.track.key(id: p0)?.interpolation == .bezier)
        #expect(log.edits.count == 1)
    }

    @Test func clickOnSelectedKeyCollapsesShiftToggles() {
        let (m, _) = makeModel()
        let both: Set = [member(.opacity, o0), member(.position, p0)]
        let g = geometry(m)
        let c = g.curve(EffectProperty.opacity.id)!
        let kp = g.keyPoint(c, c.curve.keys[0])
        let click = GraphEditorGesture(at: kp, shift: false, geometry: g, selection: both)
        #expect(click.endSelection() == [member(.opacity, o0)])
        let shift = GraphEditorGesture(at: kp, shift: true, geometry: g, selection: both)
        #expect(shift.endSelection() == [member(.position, p0)])
        let empty = GraphEditorGesture(at: CGPoint(x: 300, y: 5), shift: false, geometry: g, selection: both)
        #expect(empty.endSelection().isEmpty)
    }

    @Test func graphEditorFillsTheKeyframeAreaAndTintsValueFields() {
        let (m, _) = makeModel()
        m.expanded = [.opacity]
        m.graphEditor = true
        let v = EffectControlsView(model: m)
        v.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        v.layoutSubtreeIfNeeded()
        #expect(v.graphEditorView.isHidden == false)
        #expect(v.graphEditorView.frame.minX == v.labelWidth && v.graphEditorView.frame.maxX == 800)
        #expect(v.shownRows.contains { if case .graph = $0.kind { true } else { false } } == false)
        #expect(v.tintedFieldCount == 3)        // Position X and Y, Opacity
        // Playback: the playhead moves, the curves are not sampled again.
        let g = v.graphEditorView
        _ = g.curves
        let samples = g.sampleCount
        for f in 1...10 { m.playhead = Time(Int64(f), 10); g.movePlayhead(); g.refreshContent(); _ = g.curves }
        #expect(g.sampleCount == samples)
        m.graphEditor = false
        v.rebuild()
        #expect(v.graphEditorView.isHidden)
        #expect(v.tintedFieldCount == 0)
        #expect(v.shownRows.contains { if case .graph = $0.kind { true } else { false } })
    }
}

/// Hue keys in the Graph Editor: the drawn segment follows the short arc (COL-25), also across 0/360.
@MainActor @Suite struct GraphEditorHueTests {
    func curve(_ values: [Double], hue: Bool) -> GraphEditorCurve {
        let keys = values.enumerated().map { Keyframe(id: UUID(), time: Time(Int64($0.offset) * 2, 1), value: $0.element) }
        let o = PropertyTrack.scalar(KeyframeTrack(keys: keys)).speedOverlay(samples: 16, hue: hue)!
        return GraphEditorCurve(property: EffectProperty.opacity.id, title: "Hue", curve: o, colorIndex: 0)
    }

    @Test func wrapSegmentUsesShortArcSpan() {
        let lane = KeyframeLaneGeometry(width: 400, duration: Time(4, 1))
        let straight = curve([350, 10], hue: false), hue = curve([350, 10], hue: true)
        #expect(straight.curve.handles.first?.span == 340)
        #expect(hue.curve.handles.first?.span == 20)
        let g = GraphEditorGeometry(lane: lane, height: 240, curves: [hue])
        // Steady short arc: a flat line at 1x, not a hill from the 340 degree detour.
        let ys = Set(g.polylines(hue)[0].map { Int($0.y.rounded()) })
        #expect(ys.count == 1)
    }

    @Test func chainedKeysUnwrapAndHandlesStayRelative() {
        let h = curve([350, 10, 330], hue: true)
        #expect(h.curve.handles.map(\.span) == [20, 20, 40, 40])
        #expect(h.curve.segments.count == 2)
    }

    @Test func nonHueKeepsStraightDifference() {
        #expect(curve([350, 10], hue: false).curve.handles.first?.span == 340)
    }
}
