import Foundation
import Testing
@testable import SQCore

/// One-shot "Match Color to Clip": which clip is the reference, which frames are measured, and how the result lands on
/// the target's Color effect.
@Suite struct ColorMatchToClipTests {
    private let fd = Time(1, 25)
    private func s(_ n: Int64) -> Time { Time(n, 1) }

    private func clip(_ name: String, at start: Int64, length: Int64 = 4) -> Clip {
        Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(length)), start: s(start),
             mediaDuration: s(30))
    }

    private func track(_ clips: [Clip]) throws -> Track {
        var t = Track(kind: .video)
        for c in clips { try t.overwrite(c) }
        return t
    }

    // MARK: Picking the reference

    @Test func referenceIsTheClipUnderThePlayheadOnTheNearestOtherTrack() throws {
        let a = clip("A", at: 0, length: 10), b = clip("B", at: 2), target = clip("T", at: 3), far = clip("F", at: 0, length: 10)
        let t = Timeline(name: "t", frameDuration: fd,
                         tracks: [try track([far]), try track([a]), try track([target]), try track([b])])
        let pair = try #require(t.colorMatchPair(target: target.id, playhead: s(4)))
        // A (one below) and B (one above) are equally near: the one below wins.
        #expect(pair.reference == a.id)
        #expect(pair.referenceTime == s(4))
        #expect(pair.target == target.id)
        #expect(pair.targetTime == s(4))
        #expect(pair.source == .stacked)
    }

    @Test func hiddenTracksGeneratorsAndDisabledClipsAreNoReference() throws {
        var hidden = try track([clip("H", at: 0, length: 10)])
        hidden.isVisible = false
        var gen = clip("G", at: 0, length: 10)
        gen.generator = GeneratorRef(kind: GeneratorRef.adjustment, payload: Data())
        var off = clip("O", at: 0, length: 10)
        off.isEnabled = false
        let prev = clip("P", at: 0, length: 2), target = clip("T", at: 2)
        let t = Timeline(name: "t", frameDuration: fd,
                         tracks: [hidden, try track([gen]), try track([off]), try track([prev, target])])
        let pair = try #require(t.colorMatchPair(target: target.id, playhead: s(3)))
        #expect(pair.reference == prev.id)
        #expect(pair.source == .previous)
    }

    @Test func withoutAStackedClipThePreviousClipOnTheTrackIsMeasuredInItsMiddle() throws {
        let first = clip("1", at: 0, length: 2), prev = clip("2", at: 3, length: 3), target = clip("T", at: 6)
        let t = Timeline(name: "t", frameDuration: fd, tracks: [try track([first, prev, target])])
        let pair = try #require(t.colorMatchPair(target: target.id, playhead: s(20)))
        #expect(pair.reference == prev.id)
        #expect(pair.referenceTime == Time(112, 25))       // 3 s + 1.5 s, floored to the frame grid
        // The playhead is not on the target: its middle frame is measured too.
        #expect(pair.targetTime == s(8))
    }

    @Test func noReferenceForTheFirstLonelyClip() throws {
        let target = clip("T", at: 0)
        let t = Timeline(name: "t", frameDuration: fd, tracks: [try track([target])])
        #expect(t.colorMatchPair(target: target.id, playhead: s(1)) == nil)
        #expect(t.colorMatchPair(target: UUID(), playhead: s(1)) == nil)
    }

    // MARK: Samples

    @Test func letterboxBlackIsLeftOutOfTheSamples() {
        let px: [SIMD3<Float>] = [.zero, .zero, SIMD3(0.5, 0.4, 0.3), SIMD3(0.001, 0, 0), SIMD3(0.2, 0.2, 0.2)]
        #expect(ColorMatchSolver.pictureSamples(px) == [SIMD3(0.5, 0.4, 0.3), SIMD3(0.2, 0.2, 0.2)])
    }

    // MARK: Writing the result

    @Test func aClipWithoutGradeGetsAColourEffectWithTheWheelsAndTheReference() throws {
        var c = clip("T", at: 0)
        var w = ColorWheels()
        w.midtonesLuma = 12; w.highlights = WheelValue(hue: 30, amount: 0.2); w.saturation = 110
        let ref = ColorMatchReference(clip: UUID(), time: s(1), label: "A 00:00:01:00",
                                      stats: try #require(ColorMatchStats.measure(ColorMatchTests.picture())))
        let ok = c.applyColorMatch(ColorMatchResult(exposure: 0.4, wheels: w), reference: ref, atLocal: nil)
        #expect(ok)
        #expect(c.colorGradeEffects.count == 1)
        let e = c.color.primary
        #expect(e.wheels == w)
        #expect(e.basic.exposure == 0.4)
        #expect(e.isEnabled(.wheels))
        #expect(c.colorGradeEffects[0].colorData.match == ref)
    }

    @Test func switchedOffWheelsAreSwitchedOnAndKeyedWheelsGetAKey() throws {
        var c = clip("T", at: 0)
        var g = ClipEffect.colorGrade(ColorEffect(id: 1, inputLUT: .automatic))
        var p = AnimatedProperty(0.0)
        p.track.insert(Keyframe(time: .zero, value: 0))
        p.track.insert(Keyframe(time: s(3), value: 0))
        g.parameters[ClipEffect.colorWheelMidtonesLumaKey] = p
        g.parameters[ClipEffect.colorWheelsOnKey] = AnimatedProperty(0.0)
        c.effects = [g]
        var w = ColorWheels(); w.midtonesLuma = 20
        let ref = ColorMatchReference(clip: nil, time: .zero, label: "R",
                                      stats: try #require(ColorMatchStats.measure(ColorMatchTests.picture())))
        let ok = c.applyColorMatch(ColorMatchResult(exposure: nil, wheels: w), reference: ref, atLocal: s(1))
        #expect(ok)
        #expect(c.color(atLocal: s(1)).primary.wheels.midtonesLuma == 20)
        #expect(c.color(atLocal: s(3)).primary.wheels.midtonesLuma == 0)
        #expect(c.color.primary.isEnabled(.wheels))
    }

    @Test func clipsThatTakeNoColourRefuse() throws {
        var c = clip("T", at: 0)
        c.generator = GeneratorRef(kind: GeneratorRef.text, payload: Data())
        let ref = ColorMatchReference(clip: nil, time: .zero, label: "R",
                                      stats: try #require(ColorMatchStats.measure(ColorMatchTests.picture())))
        let ok = c.applyColorMatch(ColorMatchResult(exposure: nil, wheels: ColorWheels()), reference: ref, atLocal: nil)
        #expect(!ok)
        #expect(c.effects.isEmpty)
    }

    @Test func wheelsInPictureAreNeutralWhenSwitchedOff() {
        var e = ColorEffect(id: 1, inputLUT: .automatic)
        e.wheels.midtonesLuma = 30
        #expect(ColorMatchSolver.wheelsInPicture(e).midtonesLuma == 30)
        e.setEnabled(.wheels, false)
        #expect(ColorMatchSolver.wheelsInPicture(e).isNeutral)
    }

    // MARK: Synthetic end to end

    /// A darker, warmer copy of the reference comes back to the reference's tone and color within tolerance.
    @Test func aDarkerWarmerClipIsMatchedToItsReference() throws {
        let reference = ColorMatchTests.picture()
        let target = reference.map { p in simd_clamp3(SIMD3(p.x * 0.7, p.y * 0.6, p.z * 0.5), 0, 1) }
        let refStats = try #require(ColorMatchStats.measure(ColorMatchSolver.pictureSamples(reference)))
        let before = try #require(ColorMatchStats.measure(target))
        let effect = ClipColor.defaultEffects[0]
        let r = try #require(ColorMatchSolver.solveClip(display: ColorMatchSolver.pictureSamples(target), effect: effect,
                                                        reference: refStats))
        let ev = try #require(r.exposure)
        #expect(ev > 0.3 && ev < 1.5)                      // brightened by an Exposure step
        var graded = effect.basic; graded.exposure = ev
        let shown = ColorMatchSolver.exposed(target, from: effect.basic, to: graded).map { ColorWheelsModel.apply($0, r.wheels) }
        let after = try #require(ColorMatchStats.measure(shown))
        let luma = ColorMatchStats.luma
        // Brightness of every band within 0.02, warmth (R - B of the midtones) within 0.04.
        for (a, r) in zip(after.bands, refStats.bands) {
            let d = abs((luma * a).sum() - (luma * r).sum())
            #expect(d < 0.02, "band luma off by \(d)")
        }
        // (a strong cast: blue at 50 %, red at 70 %; the wheels' regularisation leaves a little of it)
        func warmth(_ s: ColorMatchStats) -> Float { s.midtones.x - s.midtones.z }
        let off = abs(warmth(after) - warmth(refStats))
        #expect(off < 0.04, "warmth off by \(off)")
        #expect(off < abs(warmth(before) - warmth(refStats)) / 2)
        // and much closer than before.
        #expect(ColorMatchTests.maxBandError(after, refStats) < ColorMatchTests.maxBandError(before, refStats) / 3)

        // Matching the result again changes (almost) nothing.
        var again = effect
        again.basic = graded
        again.wheels = r.wheels
        if let r2 = ColorMatchSolver.solveClip(display: shown, effect: again, reference: refStats) {
            #expect(abs((r2.exposure ?? ev) - ev) <= 0.05)
            #expect(abs(r2.wheels.midtonesLuma - r.wheels.midtonesLuma) <= 1.5)
        }
    }

    @Test func aMatchingPictureNeedsNothing() throws {
        let p = ColorMatchTests.picture()
        let s = try #require(ColorMatchStats.measure(p))
        #expect(ColorMatchSolver.solveClip(display: p, effect: ClipColor.defaultEffects[0], reference: s) == nil)
    }
}
