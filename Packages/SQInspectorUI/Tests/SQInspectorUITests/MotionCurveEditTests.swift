import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

// FB-T3: the Custom curve of a motion effect, edited with the curve popover from the Curve row.

@MainActor @Suite struct MotionCurveEditTests {
    private func setup() -> (EffectControlsModel, ClipEffect.ID) {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        let e = MotionPresets.builtIn(named: "Move From Left")!.effects[0]
        c.effects = [e]
        let m = EffectControlsModel()
        m.setClip(c)
        return (m, e.id)
    }

    @Test func dragWritesTheCustomCurveAndSelectsCustom() {
        let (m, id) = setup()
        var names: [String] = []
        m.onEdit = { _, n, _ in names.append(n) }
        let src = MotionCurveEaseSource(model: m, effect: id)
        src.beginGesture()
        src.applyEaseShape(CubicBezierEase(x1: 0.2, y1: 0.9, x2: 0.4, y2: 1).shape)
        src.applyEaseShape(CubicBezierEase(x1: 0.1, y1: 1.2, x2: 0.3, y2: 1).shape)
        src.endGesture()
        let e = m.clip!.effects[0]
        let c = e.customCurve!
        #expect(zip([c.x1, c.y1, c.x2, c.y2], [0.1, 1.2, 0.3, 1]).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(e.parameters[ClipEffect.motionCurveKey]?.value == Double(MotionCurve.custom.rawValue))
        #expect(Set(names) == ["Edit Curves"])
        if case .common(let s) = src.easeReading { #expect(CubicBezierEase(s) == e.customCurve) } else { Issue.record("no reading") }
    }

    @Test func holdChipPicksHoldAndReadingShowsTheNamedCurve() {
        let (m, id) = setup()
        let src = MotionCurveEaseSource(model: m, effect: id)
        src.applyEaseShape(.hold)
        #expect(m.clip!.effects[0].parameters[ClipEffect.motionCurveKey]?.value == Double(MotionCurve.hold.rawValue))
        if case .common(let s) = src.easeReading { #expect(s.interpolation == .hold) } else { Issue.record("no reading") }
    }
}
