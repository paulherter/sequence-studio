import Foundation
import Testing
@testable import SQCore

@Suite struct FadeCurveTests {
    private let frame = Time(1, 30)
    private func clip() -> Clip {
        Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
    }

    @Test func plainFadeIsLinearAndNoFadeIsNil() {
        var c = clip()
        #expect(c.audioFadeInCurve == nil)
        c.setAudioFadeIn(Time(1, 1), frameDuration: frame)
        #expect(c.audioFadeInCurve == .linear)
        #expect(c.audioFadeOutCurve == nil)
    }

    @Test func curvesRoundTripAndShapeTheLine() {
        var c = clip()
        c.setAudioFadeIn(Time(2, 1), frameDuration: frame)
        let mid = Time(1, 1)
        let linear = c.animation.volume.value(atLocal: mid)
        #expect(abs(linear - 0.5) < 1e-6)
        c.setAudioFadeCurve(.plus3dB, head: true)
        #expect(c.audioFadeInCurve == .plus3dB)
        let loud = c.animation.volume.value(atLocal: mid)
        #expect(abs(loud - 0.5.squareRoot()) < 0.01)
        c.setAudioFadeCurve(.minus3dB, head: true)
        #expect(c.audioFadeInCurve == .minus3dB)
        #expect(abs(c.animation.volume.value(atLocal: mid) - 0.25) < 0.01)
        c.setAudioFadeCurve(.sCurve, head: true)
        #expect(c.audioFadeInCurve == .sCurve)
        let s = c.animation.volume.value(atLocal: Time(1, 2))
        #expect(s < 0.25 - 0.01)     // slower than linear at the start
        c.setAudioFadeCurve(.linear, head: true)
        #expect(c.audioFadeInCurve == .linear)
    }

    @Test func fadeOutMirrorsTheShape() {
        var c = clip()
        c.setAudioFadeOut(Time(2, 1), frameDuration: frame)
        c.setAudioFadeCurve(.plus3dB, head: false)
        #expect(c.audioFadeOutCurve == .plus3dB)
        // Equal power: halfway through the fade out the level is sqrt(0.5), like a fade in read backwards.
        let v = c.animation.volume.value(atLocal: Time(3, 1))
        #expect(abs(v - 0.5.squareRoot()) < 0.01)
    }

    @Test func curveSurvivesLengthChange() {
        var c = clip()
        c.setAudioFadeIn(Time(1, 1), frameDuration: frame)
        c.setAudioFadeCurve(.sCurve, head: true)
        c.setAudioFadeIn(Time(2, 1), frameDuration: frame)
        #expect(c.audioFadeInCurve == .sCurve)
        #expect(c.audioFadeIn == Time(2, 1))
    }

    @Test func noFadeIgnoresCurve() {
        var c = clip()
        c.setAudioFadeCurve(.sCurve, head: true)
        #expect(c.audioFadeInCurve == nil)
        #expect(c.animation.volume.track.isEmpty)
    }
}
