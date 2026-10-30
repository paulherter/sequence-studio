import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// W1.5: color and checkbox parameters in Effect Controls (Drop Shadow) keyframe like sliders.
@MainActor @Suite struct EffectParamRowsTests {
    func rig() -> (EffectControlsModel, EffectSection) {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        let id = clip.addEffect(kind: ClipEffect.dropShadowKind)!
        let m = EffectControlsModel()
        m.setClip(clip); m.playhead = Time(6, 1)
        return (m, .effect(id, kind: ClipEffect.dropShadowKind))
    }

    final class Log { var edits: [(name: String, coalescing: Bool)] = [] }

    func logged() -> (EffectControlsModel, EffectSection, Log) {
        let (m, s) = rig(); let log = Log()
        m.onEdit = { _, n, co in log.edits.append((n, co)) }
        return (m, s, log)
    }

    func prop(_ s: EffectSection, _ key: String) -> EffectProperty { s.properties.first { $0.rawValue.hasSuffix(key) }! }

    @Test func colourAndCheckboxRowsHaveTheirKinds() {
        let (_, s) = rig()
        let color = prop(s, ClipEffect.shadowColorKey), only = prop(s, ClipEffect.shadowOnlyKey)
        #expect(color.kind == .color && !color.hasGraph)
        #expect(only.paramKind == .checkbox && !only.hasGraph)
        #expect(prop(s, ClipEffect.shadowOpacityKey).hasGraph)
        let rows = EffectControlsLayout.rows(sections: [s], collapsed: [], expanded: [color, only])
        #expect(!rows.contains { if case .graph = $0.kind { true } else { false } })
    }

    @Test func colourSetsStaticallyThenKeyframes() {
        let (m, s) = rig()
        let p = prop(s, ClipEffect.shadowColorKey)
        let red = EffectColor(red: 1, green: 0, blue: 0)
        #expect(m.setColor(p, to: red))
        #expect(m.colorValue(p) == red && !m.isAnimated(p))
        #expect(!m.isDefault(p))
        #expect(m.toggleStopwatch(p) == .added)
        m.playhead = Time(8, 1)
        #expect(m.setColor(p, to: .white))
        #expect(m.track(p)?.keyIDs.count == 2)
        m.playhead = Time(7, 1)
        let mid = m.colorValue(p)
        #expect(mid.red == 1 && mid.green > 0 && mid.green < 1)
        #expect(m.clip!.effects(at: Time(7, 1)).segments.first?.shadow?.color.y == mid.green)
        m.resetAll(p)
        #expect(m.isDefault(p) && m.colorValue(p) == .black)
    }

    @Test func colourKeysCopyPasteAndDelete() {
        let (m, s) = rig()
        let p = prop(s, ClipEffect.shadowColorKey)
        #expect(m.toggleStopwatch(p) == .added)
        m.selectKey(p, id: m.track(p)!.keyIDs[0], extend: false)
        #expect(m.copyKeys())
        m.playhead = Time(9, 1)
        #expect(m.pasteKeys())
        #expect(m.track(p)?.keyIDs.count == 2)
        m.deleteSelection()
        #expect(m.track(p)?.keyIDs.count == 1)
    }

    @Test func checkboxKeysAreHold() {
        let (m, s) = rig()
        let p = prop(s, ClipEffect.shadowOnlyKey)
        #expect(m.toggleStopwatch(p) == .added)
        m.playhead = Time(9, 1)
        #expect(m.setValue(p, to: 1))
        guard case .scalar(let t)? = m.track(p) else { Issue.record("no track"); return }
        #expect(t.keys.count == 2 && t.keys.allSatisfy { $0.interpolation == .hold })
        m.playhead = Time(8, 1)
        #expect(m.scalarValue(p) == 0)
        m.playhead = Time(9, 1)
        #expect(m.clip!.effects(at: Time(9, 1)).segments.first?.shadow?.shadowOnly == true)
    }

    // MARK: Color panel gesture (one undo step, never in the way of other edits)

    @Test func colourPanelDragIsOneUndoStep() {
        let (m, s, log) = logged()
        let p = prop(s, ClipEffect.shadowColorKey)
        m.setColorContinuously(p, to: EffectColor(red: 0.2, green: 0, blue: 0))
        m.setColorContinuously(p, to: EffectColor(red: 0.4, green: 0, blue: 0))
        m.setColorContinuously(p, to: EffectColor(red: 0.6, green: 0, blue: 0))
        #expect(log.edits.map(\.coalescing) == [false, true, true])
        #expect(m.colorValue(p).red == 0.6)
        m.endColorGesture()
        m.setColorContinuously(p, to: .white)
        #expect(log.edits.last?.coalescing == false)
    }

    @Test func checkboxDuringColourDragKeepsBoth() {
        let (m, s, log) = logged()
        let p = prop(s, ClipEffect.shadowColorKey), only = prop(s, ClipEffect.shadowOnlyKey)
        m.setColorContinuously(p, to: EffectColor(red: 1, green: 0, blue: 0))
        #expect(m.setValue(only, to: 1))
        #expect(m.colorValue(p).red == 1, "the checkbox must not revert the color")
        m.setColorContinuously(p, to: EffectColor(red: 0, green: 0, blue: 1))
        #expect(m.scalarValue(only) == 1, "the next color tick must not revert the checkbox")
        #expect(m.colorValue(p).blue == 1)
        #expect(log.edits.map(\.coalescing) == [false, false, false])
    }

    @Test func keyToggledDuringColourDragSurvivesTheNextTick() {
        let (m, s, _) = logged()
        let p = prop(s, ClipEffect.shadowColorKey)
        #expect(m.toggleStopwatch(p) == .added)
        m.setColorContinuously(p, to: EffectColor(red: 1, green: 0, blue: 0))
        m.playhead = Time(8, 1)
        m.toggleKeyAtPlayhead(p)
        m.setColorContinuously(p, to: EffectColor(red: 0, green: 1, blue: 0))
        #expect(m.track(p)?.keyIDs.count == 2)
        m.playhead = Time(6, 1)
        #expect(m.colorValue(p).red == 1)
    }

    @Test func scrubDuringColourDragKeepsItsOwnCoalescing() {
        let (m, s, log) = logged()
        let p = prop(s, ClipEffect.shadowColorKey), opacity = prop(s, ClipEffect.shadowOpacityKey)
        m.setColorContinuously(p, to: EffectColor(red: 1, green: 0, blue: 0))
        m.beginGesture()
        m.setValue(opacity, to: 10)
        m.setValue(opacity, to: 20)
        m.endColorGesture()          // a late fallback must not cut into the scrub
        m.setValue(opacity, to: 30)
        m.endGesture()
        #expect(log.edits.map(\.coalescing) == [false, false, true, true])
        #expect(m.colorValue(p).red == 1 && m.scalarValue(opacity) == 30)
    }

    @Test func colourOnSelectedKeysIsAbsolute() {
        let (m, s) = rig()
        let p = prop(s, ClipEffect.shadowColorKey)
        #expect(m.toggleStopwatch(p) == .added)
        m.playhead = Time(8, 1)
        #expect(m.setColor(p, to: EffectColor(red: 0.8, green: 0.8, blue: 0.8)))
        m.select(m.track(p)!.keyIDs.map { SummaryMember(property: p.id, keyID: $0) }, extend: false)
        let target = EffectColor(red: 1, green: 0.5, blue: 0)
        #expect(m.setColor(p, to: target))
        guard case .color(let t)? = m.track(p) else { Issue.record("no color track"); return }
        #expect(t.keys.map(\.value) == [target, target])
    }
}
