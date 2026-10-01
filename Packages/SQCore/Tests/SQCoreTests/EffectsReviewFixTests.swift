import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)

private func vclip(_ start: Int64 = 0, _ dur: Int64 = 10) -> Clip {
    Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(dur)), start: s(start))
}

private func timeline(_ c: Clip) throws -> Timeline {
    var t = Track(kind: .video)
    try t.overwrite(c)
    return Timeline(name: "t", frameDuration: fd, tracks: [t])
}

@Suite struct FrameHoldAnimationTests {
    @Test func addFrameHoldKeepsATailFadeOut() throws {
        var c = vclip()
        c.applyVideoFade(.tail, duration: s(2))               // keys at 8 s and 10 s
        var tl = try timeline(c)
        let id = try tl.addFrameHold(at: s(4))
        let h = tl.tracks[0].clips.first { $0.id == id }!
        #expect(h.holdFrame == s(14))
        #expect(h.animation.opacity.track.keys.map(\.time) == [s(4), s(6)])      // clip-local, same timeline frames
        #expect(abs(h.transform(at: s(9)).opacity - 0.5) < 1e-9)                  // still fading while the picture is held
        #expect(h.transform(at: s(5)).opacity == 1)
    }

    @Test func insertedSegmentFreezesRawValuesEvenWithTheFxToggleOff() throws {
        var c = vclip()
        c.animation.position = AnimatedProperty(Vec2(30, 40))
        c.animation.opacity = AnimatedProperty(0.5)
        c.motionEnabled = false
        var tl = try timeline(c)
        let id = try tl.insertFrameHold(at: s(4), duration: s(2))
        let h = tl.tracks[0].clips.first { $0.id == id }!
        #expect(h.animation.position.value == Vec2(30, 40))       // the stored value, not the identity the toggle renders
        #expect(h.animation.opacity.value == 0.5)
        #expect(!h.motionEnabled && h.opacityEnabled)
    }

    @Test func holdKeepsTheBlendModeAndEffectKeys() throws {
        var c = vclip()
        c.blendMode = .screen
        let e = c.addEffect(kind: ClipEffect.gaussianBlurKind)!
        c.setParameter(e, ClipEffect.blurrinessKey, to: 8)
        var tl = try timeline(c)
        let id = try tl.addFrameHold(at: s(4))
        let h = tl.tracks[0].clips.first { $0.id == id }!
        #expect(h.blendMode == .screen && h.effects.count == 1 && h.effects[0].parameters[ClipEffect.blurrinessKey]?.value == 8)
    }
}

@Suite struct PasteAttributesReviewTests {
    @Test func motionAndOpacityTogglesTravel() {
        var src = vclip()
        src.motionEnabled = false; src.opacityEnabled = false
        let out = vclip(20).pastingAttributes(from: src)
        #expect(!out.motionEnabled && !out.opacityEnabled)
    }

    @Test func pastingTwiceDoesNotStackEffects() {
        var src = vclip()
        let b = src.addEffect(kind: ClipEffect.gaussianBlurKind)!
        src.setParameter(b, ClipEffect.blurrinessKey, to: 9)
        let dst = vclip(20)
        let once = dst.pastingAttributes(from: src)
        #expect(once.effects.count == 1)
        src.setParameter(b, ClipEffect.blurrinessKey, to: 3)
        let twice = once.pastingAttributes(from: src)
        #expect(twice.effects.count == 1 && twice.effects[0].parameters[ClipEffect.blurrinessKey]?.value == 3)
    }

    @Test func differentCountsAddInstead() {
        var src = vclip()
        _ = src.addEffect(kind: ClipEffect.cropKind)
        var dst = vclip(20)
        _ = dst.addEffect(kind: ClipEffect.cropKind)
        _ = dst.addEffect(kind: ClipEffect.cropKind)
        #expect(dst.pastingAttributes(from: src).effects.count == 3)
    }
}

@Suite struct OpacityKeyFrameGridTests {
    @Test func fadeKeysSitOnFrames() {
        var c = vclip(0, 5)
        c.applyVideoFade(.head, duration: Time(1, 40), frameDuration: fd)     // 0.025 s is not a frame
        let t = c.animation.opacity.track.keys.last!.time
        #expect(t == t.snapped(to: fd))
    }

    @Test func movedKeySnapsToAFrame() {
        var c = vclip(0, 5)
        let id = c.addOpacityKey(atLocal: s(1))!
        c.moveOpacityKey(id, toLocal: Time(1234, 1000), value: 0.4, frameDuration: fd)
        let k = c.animation.opacity.track.keys.first { $0.id == id }!
        #expect(k.time == k.time.snapped(to: fd) && k.time != Time(1234, 1000))
    }

    @Test func timelineFadeUsesTheSequenceFrameGrid() throws {
        let c = vclip(0, 5)
        var tl = try timeline(c)
        try tl.fadeVideo([c.id], edge: .tail, duration: Time(1, 7))
        for k in tl.tracks[0].clips[0].animation.opacity.track.keys { #expect(k.time == k.time.snapped(to: fd)) }
    }
}
