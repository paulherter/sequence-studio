import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64, _ d: Int64 = 1) -> Time { Time(n, d) }

private func clip(_ kinds: [(String, [String: Double])], start: Int64 = 2) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(10)), start: s(start))
    for (k, v) in kinds {
        let id = c.addEffect(kind: k)!
        for (key, val) in v { c.setParameter(id, key, to: val) }
    }
    return c
}

private func layers(_ c: Clip, at t: Time) throws -> [LayerRequest] {
    var tr = Track(kind: .video)
    try tr.overwrite(c)
    return Timeline(name: "t", frameDuration: Time(1, 25), tracks: [tr]).videoLayers(at: t)
}

@Suite struct PosterizeTimeTests {
    @Test func holdsTheStartOfEachInterval() {
        // 8 fps: intervals of 1/8 s.
        #expect(PosterizeTime.heldLocal(s(0), rate: 8) == s(0))
        #expect(PosterizeTime.heldLocal(s(1, 25), rate: 8) == s(0))       // 0.04 s
        #expect(PosterizeTime.heldLocal(s(3, 25), rate: 8) == s(0))       // 0.12 s
        #expect(PosterizeTime.heldLocal(s(4, 25), rate: 8) == s(1, 8))    // 0.16 s
        #expect(PosterizeTime.heldLocal(s(1), rate: 8) == s(1))
        #expect(PosterizeTime.heldLocal(s(7, 5), rate: 8) == s(11, 8))    // 1.4 s
    }

    @Test func nonIntegerRateStaysRational() {
        #expect(PosterizeTime.heldLocal(s(1), rate: 12.5) == s(24, 25))   // 1 s = 12.5 intervals of 0.08 s: held at 12 x 0.08
        #expect(PosterizeTime.heldLocal(s(19, 100), rate: 12.5) == s(16, 100))
    }

    @Test func sourceTimeStepsAndRepeats() throws {
        let c = clip([(ClipEffect.posterizeTimeKind, [ClipEffect.posterizeRateKey: 5])])      // 0.2 s steps, clip starts at 2 s
        let a = try layers(c, at: s(2) + s(1, 25))[0].sourceTime, b = try layers(c, at: s(2) + s(4, 25))[0].sourceTime
        let n = try layers(c, at: s(2) + s(5, 25))[0].sourceTime
        #expect(a == s(10) && b == s(10))                                  // same frame held
        #expect(n == s(10) + s(1, 5))                                       // next step
    }

    @Test func noEffectOrDisabledOrOutsideChangesNothing() throws {
        var c = clip([(ClipEffect.posterizeTimeKind, [:])])
        #expect(try layers(c, at: s(2) + s(1, 25))[0].sourceTime == s(10))   // default 8 fps holds
        c.effects[0].enabled = false
        #expect(try layers(c, at: s(2) + s(4, 25))[0].sourceTime == s(10) + s(4, 25))
        #expect(clip([]).posterizedTime(at: s(5)) == s(5))
    }

    @Test func keepsSpeedAndSkipsFrameBlend() throws {
        var c = clip([(ClipEffect.posterizeTimeKind, [ClipEffect.posterizeRateKey: 4])])
        c.timeInterpolation = .frameBlend
        let l = try layers(c, at: s(2) + s(3, 10))[0]                        // held at 0.25 s
        #expect(l.sourceTime == s(10) + s(1, 4))
        #expect(l.interpolation == .frameSampling)
    }

    @Test func aHeldTailPosterizesTheHeldReadTime() {
        // Media ends where the clip does (no tail room): past the end the clip holds its last frame, and Posterize Time
        // holds the start of that frame's interval (4 fps: 11.75 s), not the raw last frame (11.96 s).
        var c = clip([(ClipEffect.posterizeTimeKind, [ClipEffect.posterizeRateKey: 4])])
        c.mediaDuration = s(20)                                          // source 10...20 = the whole media
        let fd = s(1, 25), past = s(25, 2)                                // 12.5 s, after the clip's end (12 s)
        #expect(c.heldReadTime(at: past, frameDuration: fd) == s(12) - fd)
        let tq = c.posterizedTime(at: past, frameDuration: fd)
        #expect(tq == s(47, 4))                                           // 11.75 s
        #expect(c.sourceTime(at: tq, frameDuration: fd) == s(79, 4))      // 19.75 s
        #expect(c.posterizedTime(at: past) == past)                       // without the frame duration: unchanged
    }

    @Test func aHeldHeadPosterizesToTheClipStart() {
        var c = clip([(ClipEffect.posterizeTimeKind, [ClipEffect.posterizeRateKey: 4])])
        c.source = TimeRange(start: .zero, duration: s(10))              // no head room
        c.mediaDuration = s(10)
        #expect(c.posterizedTime(at: s(3, 2), frameDuration: s(1, 25)) == s(2))   // held read = clip start = interval start
    }

    @Test func oneFrameOfHandleReadsThatFrameUnposterized() {
        // One whole frame of media beyond the end is not "no room": the transition reads the real handle frame.
        var c = clip([(ClipEffect.posterizeTimeKind, [ClipEffect.posterizeRateKey: 4])])
        let fd = s(1, 25)
        c.mediaDuration = s(20) + fd
        let past = s(25, 2)
        #expect(c.heldReadTime(at: past, frameDuration: fd) == past)
        #expect(c.posterizedTime(at: past, frameDuration: fd) == past)
        c.mediaDuration = s(20) + fd - s(1, 100)                          // a sliver short of a whole frame: held again
        #expect(c.posterizedTime(at: past, frameDuration: fd) == s(47, 4))
    }

    @Test func catalogAndGhostFramePreset() {
        let spec = EffectCatalog.spec(for: ClipEffect.posterizeTimeKind)
        #expect(spec?.params.first?.defaultValue == 8)
        let kinds = MotionPresets.builtIn(named: "Ghost Frame")?.effects.map(\.kind) ?? []
        #expect(kinds.contains(ClipEffect.posterizeTimeKind) && kinds.contains(ClipEffect.rgbSplitKind) && kinds.contains(ClipEffect.glowKind))
    }
}

@Suite struct DateStampTests {
    @Test func formats() {
        let d = DateStamp.moment(year: 1998, month: 7, day: 14, hour: 22, minute: 32, elapsedSeconds: 5)
        #expect(DateStamp.text(format: 0, at: d) == "JUL 14 1998")
        #expect(DateStamp.text(format: 1, at: d) == "14.07.1998")
        #expect(DateStamp.text(format: 2, at: d) == "07/14/1998")
        #expect(DateStamp.text(format: 3, at: d) == "10:32 PM")
        #expect(DateStamp.text(format: 4, at: d) == "22:32:05")
        #expect(DateStamp.text(format: 5, at: d) == "JUL 14 1998  10:32 PM")
        #expect(DateStamp.text(format: 6, at: d) == "14.07.1998  22:32:05")
        let noon = DateStamp.moment(year: 2001, month: 1, day: 1, hour: 0, minute: 5, elapsedSeconds: 0)
        #expect(DateStamp.text(format: 3, at: noon) == "12:05 AM")
    }

    @Test func clockAdvancesAndRollsOver() {
        let d = DateStamp.moment(year: 1999, month: 12, day: 31, hour: 23, minute: 59, elapsedSeconds: 75)
        #expect(DateStamp.text(format: 6, at: d) == "01.01.2000  00:00:15")
    }

    @Test func effectAddsATextLayerOnTheClipTransform() throws {
        let c = clip([(ClipEffect.dateStampKind, [ClipEffect.stampFormatKey: 4, ClipEffect.stampSizeKey: 5])])
        let ls = try layers(c, at: s(2) + s(7, 2))                          // 3.5 s into the clip
        #expect(ls.count == 2)
        #expect(ls[0].generator == nil && ls[1].generator?.kind == GeneratorRef.dateStamp)
        let spec = DateStampSpec.decode(try #require(ls[1].generator))
        #expect(spec?.text == "22:32:03")
        #expect(spec?.corner == .bottomRight)
        #expect(spec.map { abs($0.fontSize - 0.05 * Double(Timeline(name: "t", frameDuration: Time(1, 25)).format.height)) < 1e-9 } == true)
        #expect(ls[1].clipDuration == c.duration && ls[1].transform == ls[0].transform)
    }

    @Test func blinkHidesTheSecondHalfSecond() throws {
        let c = clip([(ClipEffect.dateStampKind, [ClipEffect.stampBlinkKey: 1])])
        #expect(try layers(c, at: s(2) + s(1, 4)).count == 2)
        #expect(try layers(c, at: s(2) + s(3, 4)).count == 1)
    }

    @Test func disabledOrAbsentAddsNothing() throws {
        var c = clip([(ClipEffect.dateStampKind, [:])])
        c.effects[0].enabled = false
        #expect(try layers(c, at: s(3)).count == 1)
    }

    @Test func catalogDefaultsInRange() {
        let spec = EffectCatalog.spec(for: ClipEffect.dateStampKind)
        #expect(spec != nil)
        for p in spec?.params ?? [] where p.kind.isScalar { #expect(p.range.contains(p.defaultValue), "\(p.key)") }
    }
}
