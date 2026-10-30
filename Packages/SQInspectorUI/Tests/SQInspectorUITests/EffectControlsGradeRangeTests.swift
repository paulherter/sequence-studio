import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// COLOR-GRADE-LINKS follow-up: a range grade's range is shown and edited in Effect Controls.
@MainActor @Suite struct EffectControlsGradeRangeTests {
    func rig() -> (EffectControlsModel, ClipEffect.ID) {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        _ = clip.addEffect(kind: ClipEffect.colorKind)
        let id = clip.addRangeGrade(TimeRange(start: Time(2, 1), end: Time(6, 1)))!
        let m = EffectControlsModel()
        m.setClip(clip)
        return (m, id)
    }

    @Test func rangeIsReadAndListed() {
        let (m, id) = rig()
        #expect(m.gradeRange(id) == TimeRange(start: Time(2, 1), end: Time(6, 1)))
        #expect(m.gradeRangeEffects == [id])
    }

    @Test func layoutHasOneRangeRowUnderTheRangeSection() {
        let (m, id) = rig()
        let rows = EffectControlsLayout.rows(sections: m.visibleSections, collapsed: [], expanded: [], gradeRanges: m.gradeRangeEffects)
        let n = rows.filter { if case .gradeRange(id) = $0.kind { true } else { false } }.count
        #expect(n == 1)
        let none = EffectControlsLayout.rows(sections: m.visibleSections, collapsed: [], expanded: [])
        #expect(!none.contains { if case .gradeRange = $0.kind { true } else { false } })
    }

    @Test func editingStartAndEndIsOneUndoStepEachAndClamps() {
        let (m, id) = rig()
        var log: [String] = []
        m.onEdit = { _, n, _ in log.append(n) }
        m.setGradeRange(id, start: Time(1, 1), end: nil)
        #expect(m.gradeRange(id) == TimeRange(start: Time(1, 1), end: Time(6, 1)))
        m.setGradeRange(id, start: nil, end: Time(99, 1))                    // clamped to the clip end
        #expect(m.gradeRange(id)?.end == Time(10, 1))
        m.setGradeRange(id, start: Time(9, 1), end: Time(3, 1))              // end before start: rejected
        #expect(m.gradeRange(id) == TimeRange(start: Time(1, 1), end: Time(10, 1)))
        #expect(log == ["Set Grade Range", "Set Grade Range"])
    }

    @Test func wholeClipDropsTheRange() {
        let (m, id) = rig()
        m.setGradeWholeClip(id)
        #expect(m.gradeRange(id) == nil)
        #expect(m.gradeRangeEffects.isEmpty)
    }

    @Test func fadesAreEditedAsOneUndoStepAndClamp() {
        let (m, id) = rig()
        var log: [String] = []
        m.onEdit = { _, n, _ in log.append(n) }
        m.setGradeFades(id, fadeIn: Time(1, 1), fadeOut: nil)
        #expect(m.gradeFades(id).fadeIn == Time(1, 1) && m.gradeFades(id).fadeOut == .zero)
        m.setGradeFades(id, fadeIn: nil, fadeOut: Time(99, 1))                // clamped to the range length (4 s)
        #expect(m.gradeFades(id).fadeOut == Time(4, 1))
        m.setGradeFades(id, fadeIn: Time(1, 1), fadeOut: nil)                 // unchanged: no edit
        #expect(log == ["Set Grade Fade", "Set Grade Fade"])
    }
}
