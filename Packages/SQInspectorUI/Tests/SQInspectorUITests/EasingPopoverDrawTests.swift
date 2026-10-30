import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQInspectorUI

/// The curve popover on the shared toolkit (Windows): chips, the speed curve editor, Save, and the panel's triggers.
@MainActor @Suite struct EasingPopoverDrawTests {
    /// Position with two keys, both selected.
    private func model() -> EffectControlsModel {
        let m = EffectControlsModel()
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        c.animation.position.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(0, 0)), Keyframe(time: Time(2, 1), value: Vec2(100, 0))])
        m.onEdit = { n, _, _ in m.setClip(n) }
        m.setClip(c)
        for k in c.animation.position.track.keys { m.selectKey(.position, id: k.id, extend: true) }
        return m
    }

    private func mid(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    @Test func aChipAppliesItsCurveAndLightsUp() throws {
        let m = model(), pop = EasingPopoverDraw(source: m)
        let i = try #require(pop.chips.firstIndex(of: .curve(.easeOut)))
        pop.mouseDown(at: mid(pop.chipFrame(i)))
        pop.mouseUp(at: mid(pop.chipFrame(i)))
        guard case .common(let s) = m.easeReading else { Issue.record("not common"); return }
        #expect(s.isApproximatelyEqual(to: EasingCurve.easeOut.shape))
        // Springs bake keys: offered for keyframes.
        #expect(pop.chips.contains { if case .spring = $0 { true } else { false } })
        var c = Canvas(width: Float(EasingPopoverDraw.size.width), height: Float(EasingPopoverDraw.size.height), atlas: nil, scale: 1)
        pop.draw(&c, theme: DrawTheme())
        #expect(!c.list.quads.isEmpty)
    }

    @Test func draggingAHandleIsOneGestureOnTheSource() throws {
        let m = model()
        var names: [(String, Bool)] = []
        m.onEdit = { n, name, co in names.append((name, co)); m.setClip(n) }
        let pop = EasingPopoverDraw(source: m)
        let e = pop.editor
        let seg = try #require(e.segment)
        let knob = e.geometry.handleEnd(seg, side: .out)
        let at = CGPoint(x: knob.x, y: e.geometry.key(seg, side: .out).y)
        #expect(e.handle(at: at) == .out)
        pop.mouseDown(at: at)
        pop.mouseDragged(to: CGPoint(x: at.x + 40, y: at.y))
        pop.mouseDragged(to: CGPoint(x: at.x + 60, y: at.y))
        pop.mouseUp(at: CGPoint(x: at.x + 60, y: at.y))
        #expect(names.count == 2 && names.first?.1 == false && names.last?.1 == true)
        guard case .common(let s) = m.easeReading else { Issue.record("not common"); return }
        #expect(s.out.dx > EaseShape.linear.out.dx)
    }

    @Test func saveHandsTheShapeAndTypedName() {
        let m = model(), pop = EasingPopoverDraw(source: m)
        var got: (EaseShape, String)?
        pop.onSave = { got = ($0, $1) }
        pop.mouseDown(at: mid(EasingPopoverDraw.nameFrame))
        for ch in "Snap" { _ = pop.key(.character(ch), modifiers: []) }
        _ = pop.key(.enter, modifiers: [])
        #expect(got?.1 == "Snap" && got?.0 == .linear)
        #expect(pop.name.text.isEmpty)
    }

    @Test func motionCurveRowHasTheEditCurveButton() throws {
        let m = EffectControlsModel()
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        let fx = ClipEffect(kind: ClipEffect.moveKind)
        c.effects = [fx]
        m.setClip(c)
        m.collapsedSections = []
        let p = EffectControlsDrawPanel(model: m)
        p.size = CGSize(width: 420, height: 3000)
        p.relayout()
        let row = try #require(p.rows.first {
            if case .property(.fx(_, _, let key)) = $0.kind { key == ClipEffect.motionCurveKey } else { false }
        }, "\(p.rows.map(\.kind))")
        guard case .property(let prop) = row.kind else { return }
        var opened: (any EaseCurveSource)?
        p.onEaseCurve = { s, _ in opened = s }
        let g = ControlsGrid(width: 420)
        let popupW = min(g.valueMaxX - ControlsGrid.resetWidth - ControlsGrid.gap - ControlsGrid.valueX, ControlsMetrics.Portable.popupWidth)
        let x = ControlsGrid.valueX + popupW + ControlsGrid.gap + ControlsGrid.resetWidth / 2
        let at = CGPoint(x: x, y: row.y + row.height / 2)
        #expect(p.target(at: at) == .curve(prop))
        p.mouseDown(at: at, clickCount: 1, modifiers: [])
        p.mouseUp(at: at)
        #expect(opened is MotionCurveEaseSource)
    }
}
