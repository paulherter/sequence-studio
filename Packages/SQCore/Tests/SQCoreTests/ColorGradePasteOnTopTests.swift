import Foundation
import Testing
@testable import SQCore

/// Paste Grade "Add on top": the copied Color effects stack behind the target's own (ids and keys of those stay).
@Suite struct ColorGradePasteOnTopTests {
    static func graded(_ exposure: Float) -> Clip {
        var c = ColorGradeEffectTests.picture()
        var g = ClipColor.default
        g.effects[0].basic.exposure = exposure
        c.color = g
        return c
    }

    @Test func addsBehindExistingEffectsAndKeepsIDs() {
        var dst = Self.graded(1)
        let before = dst.colorGradeEffects
        dst.addColorGradeOnTop(Self.graded(2).colorGradeEffects)
        let now = dst.colorGradeEffects
        #expect(now.count == before.count + 1)
        #expect(now[0] == before[0], "the target's own grade is untouched")
        #expect(now.last?.id != before[0].id)
    }

    @Test func onAClipWithoutGradeItEqualsReplace() {
        var a = ColorGradeEffectTests.picture(), b = a
        let fx = Self.graded(2).colorGradeEffects
        a.addColorGradeOnTop(fx)
        b.replaceColorGrade(with: fx)
        #expect(a.colorGradeEffects.map(\.parameters) == b.colorGradeEffects.map(\.parameters))
    }

    @Test func refusedOnClipsThatTakeNoColor() {
        var audio = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(4, 1)),
                         start: .zero, mediaDuration: Time(10, 1))
        audio.addColorGradeOnTop(Self.graded(2).colorGradeEffects)
        #expect(audio.effects.isEmpty)
    }
}
