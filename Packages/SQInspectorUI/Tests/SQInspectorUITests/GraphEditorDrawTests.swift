import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQInspectorUI

/// The Graph Editor on the shared toolkit (Windows): the Mac `GraphEditorView` gestures, keys and toolbar through the panel.
@MainActor @Suite struct GraphEditorDrawTests {
    private let o0 = UUID(), o1 = UUID()

    private func view() -> EffectControlsDrawView {
        var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        clip.animation.opacity.track = KeyframeTrack(keys: [Keyframe(id: o0, time: Time(0, 1), value: 0),
                                                            Keyframe(id: o1, time: Time(4, 1), value: 1)])
        let m = EffectControlsModel()
        m.onEdit = { c, _, _ in m.setClip(c) }
        m.setClip(clip)
        m.graphShowAll = true
        m.graphSnap = false
        if !m.graphEditor { m.toggleGraphEditor() }
        let v = EffectControlsDrawView(model: m)
        v.persistLabelWidth = { _ in }
        v.size = CGSize(width: 900, height: 400)
        v.relayout()
        return v
    }

    private func toPanel(_ v: EffectControlsDrawView, _ p: CGPoint) -> CGPoint { CGPoint(x: p.x + v.laneX, y: p.y + v.top) }

    @Test func editorReplacesTheLanesAndDraws() {
        let v = view()
        #expect(v.part(at: CGPoint(x: v.laneX + 100, y: v.top + 50)) == .graphEditor)
        #expect(v.graphEditor.size == v.lanesSize)
        var c = Canvas(width: 900, height: 400, atlas: nil, scale: 1)
        v.draw(&c)
        #expect(!c.list.quads.isEmpty)
        #expect(v.graphEditor.geometry.curve(EffectProperty.opacity.id) != nil)
    }

    @Test func keyDragMovesTheKeyInOneStep() throws {
        let v = view(), m = v.model
        var steps: [String] = []
        let pass = m.onEdit
        m.onEdit = { c, n, k in steps.append(n); pass?(c, n, k) }
        let g = v.graphEditor.geometry
        let c = try #require(g.curve(EffectProperty.opacity.id))
        let start = toPanel(v, g.keyPoint(c, c.curve.keys[1]))
        let one = g.lane.pointsPerSecond
        v.mouseDown(at: start, clickCount: 1, modifiers: [])
        for i in 1...10 { v.mouseDragged(to: CGPoint(x: start.x - one * CGFloat(i) / 10, y: start.y)) }
        v.mouseUp(at: CGPoint(x: start.x - one, y: start.y))
        #expect(m.clip!.animation.opacity.track.key(id: o1)?.time == Time(3, 1))
        #expect(Set(steps).count == 1)
    }

    @Test func escapeDuringAMarqueeRestoresTheSelection() throws {
        let v = view(), m = v.model
        let g = v.graphEditor.geometry
        let c = try #require(g.curve(EffectProperty.opacity.id))
        let k0 = g.keyPoint(c, c.curve.keys[0]), k1 = g.keyPoint(c, c.curve.keys[1])
        let before = Set([SummaryMember(property: EffectProperty.opacity.id, keyID: o0)])
        m.select(Array(before), extend: false)
        let origin = toPanel(v, CGPoint(x: k1.x + 30, y: min(k0.y, k1.y) - 20))
        v.mouseDown(at: origin, clickCount: 1, modifiers: [])
        v.mouseDragged(to: toPanel(v, CGPoint(x: k1.x - 20, y: max(k0.y, k1.y) + 20)))
        #expect(m.selection.contains(SummaryMember(property: EffectProperty.opacity.id, keyID: o1)))
        #expect(v.key(.escape, modifiers: []))
        v.mouseUp(at: origin)
        #expect(m.selection == before)
    }

    @Test func toolbarSnapTogglesAndShortcutsRun() {
        let v = view(), m = v.model
        let frames = v.graphEditor.toolbarFrames()
        #expect(frames.count == 8)
        let snap = toPanel(v, CGPoint(x: frames[1].midX, y: frames[1].midY))
        #expect(v.help(at: snap) == "Snap")
        v.mouseDown(at: snap, clickCount: 1, modifiers: []); v.mouseUp(at: snap)
        #expect(m.graphSnap)
        v.mouseDown(at: toPanel(v, CGPoint(x: 100, y: 50)), clickCount: 1, modifiers: []); v.mouseUp(at: toPanel(v, CGPoint(x: 100, y: 50)))
        #expect(v.key(.character("a"), modifiers: .command))
        #expect(m.selection.count == 2)
        #expect(GraphEditorShortcut.resolve(.function(9), modifiers: .shift) == .ease(.easeIn))
    }

    @Test func rightClickOffersTheKeyMenu() throws {
        let v = view()
        var shown: [SQMenuItem] = []
        v.onMenu = { items, _ in shown = items }
        let g = v.graphEditor.geometry
        let c = try #require(g.curve(EffectProperty.opacity.id))
        v.mouseDown(at: toPanel(v, g.keyPoint(c, c.curve.keys[0])), clickCount: 1, modifiers: .secondary)
        #expect(shown.map(\.title).contains("Delete"))
    }
}
