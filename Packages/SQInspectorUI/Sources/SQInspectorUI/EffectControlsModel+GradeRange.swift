import Foundation
import SQCore

/// COLOR-GRADE-LINKS follow-up: range of a range grade (a Color effect with `colorRange`) edited in Effect Controls.
extension EffectControlsModel {
    /// Steps of the Color Graph effect `effect` (the Pro grade row's "N Steps").
    public func colorGraphStepCount(_ effect: ClipEffect.ID) -> Int {
        clip?.effects.first { $0.id == effect && $0.isColorGraph }?.colorGraph?.steps.count ?? 0
    }

    /// The clip-local range of Color effect `effect`, nil for a whole-clip grade.
    public func gradeRange(_ effect: ClipEffect.ID) -> TimeRange? {
        clip?.effects.first { $0.id == effect && $0.isColor }?.colorRange
    }

    /// Color effects of the shown clip that grade only a range (they get a Range row under their header).
    public var gradeRangeEffects: [ClipEffect.ID] {
        clip?.effects.filter(\.isRangeGrade).map(\.id) ?? []
    }

    /// Moves the start and/or end (clip-local, cut to the clip). Refused when the result is empty or reversed.
    public func setGradeRange(_ effect: ClipEffect.ID, start: Time?, end: Time?) {
        guard var c = workingClip, let r = c.effects.first(where: { $0.id == effect })?.colorRange else { return }
        let s = max(start ?? r.start, .zero), e = min(end ?? r.end, c.duration)
        guard s < e else { return }
        let new = TimeRange(start: s, end: e)
        guard new != r, c.setColorRange(effect, new) else { return }
        commit(c, "Set Grade Range")
    }

    /// Drops the range: the effect grades the whole clip again.
    public func setGradeWholeClip(_ effect: ClipEffect.ID) {
        guard var c = workingClip, c.setColorRange(effect, nil) else { return }
        commit(c, "Grade Whole Clip")
    }

    /// Fade-in / fade-out lengths of a range grade (soft edges); zero = hard edge.
    public func gradeFades(_ effect: ClipEffect.ID) -> (fadeIn: Time, fadeOut: Time) {
        let fx = clip?.effects.first { $0.id == effect && $0.isColor }
        return (fx?.colorFadeIn ?? .zero, fx?.colorFadeOut ?? .zero)
    }

    /// Sets one or both fade lengths (clamped to the range). One undo step.
    public func setGradeFades(_ effect: ClipEffect.ID, fadeIn: Time?, fadeOut: Time?) {
        guard var c = workingClip else { return }
        let cur = gradeFades(effect)
        guard c.setColorRangeFades(effect, fadeIn: fadeIn ?? cur.fadeIn, fadeOut: fadeOut ?? cur.fadeOut) else { return }
        let new = c.effects.first { $0.id == effect }
        guard new?.colorFadeIn != clip?.effects.first(where: { $0.id == effect })?.colorFadeIn
            || new?.colorFadeOut != clip?.effects.first(where: { $0.id == effect })?.colorFadeOut else { return }
        commit(c, "Set Grade Fade")
    }
}
