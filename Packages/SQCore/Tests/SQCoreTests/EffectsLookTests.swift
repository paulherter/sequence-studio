import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)

private func videoClip(start: Int64 = 0, dur: Int64 = 5, link: UUID? = nil) -> Clip {
    Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(dur)), start: s(start), link: link)
}

private func effect(_ kind: String, _ values: [String: Double]) -> ClipEffect {
    var e = ClipEffect.make(kind: kind)!
    for (k, v) in values { e.parameters[k] = AnimatedProperty(v) }
    return e
}

@Suite struct EffectEvaluationTests {
    @Test func identityEffectsAreNone() {
        var c = videoClip()
        c.effects = [effect(ClipEffect.cropKind, [:]), effect(ClipEffect.gaussianBlurKind, [:]),
                     effect(ClipEffect.roundedCornersKind, [ClipEffect.radiusKey: 0])]
        let e = c.effects(at: s(1))
        #expect(e == ClipEffects.none)
        #expect(e.isIdentity)
    }

    @Test func cropIsFractionOfFrame() {
        var c = videoClip()
        c.effects = [effect(ClipEffect.cropKind, [ClipEffect.cropLeftKey: 10, ClipEffect.cropBottomKey: 25])]
        let crop = c.effects(at: s(1)).pre.crop
        #expect(abs(crop.left - 0.10) < 1e-12)
        #expect(abs(crop.bottom - 0.25) < 1e-12)
        #expect(crop.top == 0 && crop.right == 0)
        #expect(!c.effects(at: s(1)).isIdentity)
    }

    @Test func totalCropIsEmpty() {
        var c = videoClip()
        c.effects = [effect(ClipEffect.cropKind, [ClipEffect.cropLeftKey: 50, ClipEffect.cropRightKey: 50])]
        #expect(c.effects(at: s(1)).isEmpty)
        c.effects = [effect(ClipEffect.cropKind, [ClipEffect.cropLeftKey: 40, ClipEffect.cropRightKey: 50])]
        #expect(!c.effects(at: s(1)).isEmpty)
        c.effects = [effect(ClipEffect.cropKind, [ClipEffect.cropTopKey: 100])]
        #expect(c.effects(at: s(1)).isEmpty)
    }

    @Test func cropValuesAreClamped() {
        var c = videoClip()
        c.effects = [effect(ClipEffect.cropKind, [ClipEffect.cropLeftKey: -5, ClipEffect.cropTopKey: 400])]
        let crop = c.effects(at: s(1)).pre.crop
        #expect(crop.left == 0 && crop.top == 1)
    }

    @Test func blurZeroIsIdentityAndPositiveIsSigma() {
        var c = videoClip()
        c.effects = [effect(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 0])]
        #expect(c.effects(at: s(1)).blur == 0)
        c.effects = [effect(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 12])]
        #expect(c.effects(at: s(1)).blur == ClipEffect.gaussianSigma(blurriness: 12))
        #expect(!c.effects(at: s(1)).isIdentity)
    }

    @Test func blurIsAnimatableClipLocal() {
        var c = videoClip(start: 2, dur: 4)
        var e = ClipEffect.make(kind: ClipEffect.gaussianBlurKind)!
        e.parameters[ClipEffect.blurrinessKey] = AnimatedProperty(0.0, track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: 0.0), Keyframe(time: s(4), value: 40.0)]))
        c.effects = [e]
        #expect(c.effects(at: s(2)).blur == 0)
        #expect(abs(c.effects(at: s(4)).blur - ClipEffect.gaussianSigma(blurriness: 20)) < 1e-9)
    }

    @Test func disabledEffectIsAbsent() {
        var c = videoClip()
        var e = effect(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 30])
        e.enabled = false
        c.effects = [e]
        #expect(c.effects(at: s(1)) == ClipEffects.none)
    }

    @Test func listOrderDecidesWhetherMasksComeBeforeOrAfterTheBlur() {
        var c = videoClip()
        let blur = effect(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 10])
        let round = effect(ClipEffect.roundedCornersKind, [ClipEffect.radiusKey: 30])
        c.effects = [round, blur]
        var e = c.effects(at: s(1))
        #expect(e.pre.cornerRadius == 30 && e.post.cornerRadius == 0)
        c.effects = [blur, round]
        e = c.effects(at: s(1))
        #expect(e.pre.cornerRadius == 0 && e.post.cornerRadius == 30)
    }

    @Test func withoutBlurEverythingIsOnePass() {
        var c = videoClip()
        c.effects = [effect(ClipEffect.gaussianBlurKind, [:]), effect(ClipEffect.roundedCornersKind, [ClipEffect.radiusKey: 30])]
        let e = c.effects(at: s(1))
        #expect(e.pre.cornerRadius == 30 && e.post == EffectMasks.none)
        #expect(e.cornerRadius == 30)
    }

    @Test func secondInstanceCombines() {
        var c = videoClip()
        c.effects = [effect(ClipEffect.cropKind, [ClipEffect.cropLeftKey: 10, ClipEffect.cropTopKey: 5]),
                     effect(ClipEffect.cropKind, [ClipEffect.cropLeftKey: 20]),
                     effect(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 3]),
                     effect(ClipEffect.gaussianBlurKind, [ClipEffect.blurrinessKey: 4])]
        let e = c.effects(at: s(1))
        #expect(abs(e.pre.crop.left - 0.20) < 1e-12)          // the larger inset wins
        #expect(abs(e.pre.crop.top - 0.05) < 1e-12)
        #expect(abs(e.blur - ClipEffect.gaussianSigma(blurriness: 5)) < 1e-12)                       // Gaussians add in quadrature
    }

    @Test func emptyCropLeavesNoLayer() throws {
        var c = videoClip()
        c.effects = [effect(ClipEffect.cropKind, [ClipEffect.cropLeftKey: 100])]
        var t = Track(kind: .video)
        try t.overwrite(c)
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [t])
        #expect(tl.videoLayers(at: s(1)).isEmpty)
        c.effects = [effect(ClipEffect.cropKind, [ClipEffect.cropLeftKey: 20])]
        var t2 = Track(kind: .video)
        try t2.overwrite(c)
        let tl2 = Timeline(name: "t", frameDuration: fd, tracks: [t2])
        #expect(abs(tl2.videoLayers(at: s(1))[0].effects.pre.crop.left - 0.2) < 1e-12)
    }

    @Test func layerRequestCarriesBlendMode() throws {
        var c = videoClip()
        c.blendMode = .multiply
        var t = Track(kind: .video)
        try t.overwrite(c)
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [t])
        #expect(tl.videoLayers(at: s(1))[0].blendMode == .multiply)
    }
}

@Suite struct EffectInstanceTests {
    @Test func secondInstanceGetsItsOwnId() {
        var c = videoClip()
        let a = c.addEffect(kind: ClipEffect.gaussianBlurKind)!
        let b = c.addEffect(kind: ClipEffect.gaussianBlurKind)!
        #expect(a != b)
        #expect(c.effects.map(\.id) == [a, b])
        let r1 = c.addEffect(kind: "nonsense")
        #expect(r1 == nil)
    }

    @Test func reorderChangesEvaluationOrder() {
        var c = videoClip()
        let blur = c.addEffect(kind: ClipEffect.gaussianBlurKind)!
        let round = c.addEffect(kind: ClipEffect.roundedCornersKind)!
        c.setParameter(blur, ClipEffect.blurrinessKey, to: 10)
        #expect(c.effects(at: s(1)).pre.cornerRadius == 0)       // blur first: corners after
        #expect(c.effects(at: s(1)).post.cornerRadius == 24)
        let r2 = c.moveEffect(round, to: 0)
        #expect(r2)
        #expect(c.effects.map(\.id).first == round)
        #expect(c.effects(at: s(1)).pre.cornerRadius == 24)
        #expect(c.effects(at: s(1)).post.cornerRadius == 0)
    }

    @Test func moveClampsAndRejectsUnknown() {
        var c = videoClip()
        let a = c.addEffect(kind: ClipEffect.cropKind)!
        let b = c.addEffect(kind: ClipEffect.gaussianBlurKind)!
        let r3 = c.moveEffect(a, to: 99)
        #expect(r3)
        #expect(c.effects.map(\.id) == [b, a])
        let r4 = c.moveEffect(UUID(), to: 0)
        #expect(!r4)
        let r5 = c.moveEffect(a, to: 1)
        #expect(!r5)            // already there
    }

    @Test func duplicateCopiesValuesWithNewIdsRightAfter() {
        var c = videoClip()
        let a = c.addEffect(kind: ClipEffect.gaussianBlurKind)!
        _ = c.addEffect(kind: ClipEffect.cropKind)
        c.setParameter(a, ClipEffect.blurrinessKey, to: 7)
        let copy = c.duplicateEffect(a)!
        #expect(copy != a)
        #expect(c.effects.map(\.id)[1] == copy)
        #expect(c.effects.count == 3)
        #expect(c.effects[1].parameters[ClipEffect.blurrinessKey]?.value == 7)
    }

    @Test func removeEffectById() {
        var c = videoClip()
        let a = c.addEffect(kind: ClipEffect.gaussianBlurKind)!
        let b = c.addEffect(kind: ClipEffect.gaussianBlurKind)!
        let r6 = c.removeEffect(a)
        #expect(r6)
        #expect(c.effects.map(\.id) == [b])
        let r7 = c.removeEffect(a)
        #expect(!r7)
    }

    @Test func timelineEditIsOneUndoableReplace() throws {
        var c = videoClip()
        var t = Track(kind: .video)
        try t.overwrite(c)
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [t])
        _ = c.addEffect(kind: ClipEffect.cropKind)
        try tl.replaceClip(c)
        #expect(tl.tracks[0].clips[0].effects.count == 1)
    }
}

@Suite struct BlendModeTests {
    @Test func defaultsToNormalAndIsListedInAdobeOrder() {
        #expect(videoClip().blendMode == .normal)
        #expect(BlendMode.allCases.map(\.title) == ["Normal", "Dissolve",
                                                       "Darken", "Multiply", "Color Burn", "Linear Burn", "Darker Color",
                                                       "Lighten", "Screen", "Color Dodge", "Add", "Lighter Color",
                                                       "Overlay", "Soft Light", "Hard Light", "Vivid Light", "Linear Light",
                                                       "Pin Light", "Hard Mix",
                                                       "Difference", "Exclusion", "Subtract", "Divide",
                                                       "Hue", "Saturation", "Color", "Luminosity"])
    }

    @Test func roundTripsAndOldFilesDecodeAsNormal() throws {
        var c = videoClip()
        c.blendMode = .screen
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Clip.self, from: data).blendMode == .screen)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "blendMode")
        let old = try JSONSerialization.data(withJSONObject: obj)
        #expect(try JSONDecoder().decode(Clip.self, from: old).blendMode == .normal)
    }

}

@Suite struct VideoFadeTests {
    @Test func fadeInOnFiveSecondClip() {
        var c = videoClip(dur: 5)
        c.applyVideoFade(.head, duration: s(1))
        let keys = c.animation.opacity.track.keys
        #expect(keys.map(\.time) == [s(0), s(1)])
        #expect(keys.map(\.value) == [0, 1])
    }

    @Test func fadeOutOnFiveSecondClip() {
        var c = videoClip(dur: 5)
        c.applyVideoFade(.tail, duration: s(1))
        let keys = c.animation.opacity.track.keys
        #expect(keys.map(\.time) == [s(4), s(5)])
        #expect(keys.map(\.value) == [1, 0])
    }

    @Test func shortClipClampsToHalf() {
        var c = videoClip(dur: 1)
        c.applyVideoFade(.head, duration: s(5))
        #expect(c.animation.opacity.track.keys.map(\.time) == [s(0), Time(1, 2)])
        #expect(OpacityFade.clamped(s(5), clipDuration: s(1)) == Time(1, 2))
        #expect(OpacityFade.clamped(Time(1, 4), clipDuration: s(1)) == Time(1, 4))
    }

    @Test func fadeKeepsStaticOpacityAsTarget() {
        var c = videoClip(dur: 5)
        c.animation.opacity = AnimatedProperty(0.6)
        c.applyVideoFade(.head, duration: s(1))
        #expect(c.animation.opacity.track.keys.map(\.value) == [0, 0.6])
        #expect(abs(c.transform(at: c.start + Time(1, 2)).opacity - 0.3) < 1e-9)
    }

    @Test func fadeInThenOutKeepsBoth() {
        var c = videoClip(dur: 5)
        c.applyVideoFade(.head, duration: s(1))
        c.applyVideoFade(.tail, duration: s(1))
        #expect(c.animation.opacity.track.keys.map(\.time) == [s(0), s(1), s(4), s(5)])
        #expect(c.animation.opacity.track.keys.map(\.value) == [0, 1, 1, 0])
    }

    @Test func repeatingAFadeReplacesIt() {
        var c = videoClip(dur: 5)
        c.applyVideoFade(.head, duration: s(1))
        c.applyVideoFade(.head, duration: s(2))
        #expect(c.animation.opacity.track.keys.map(\.time) == [s(0), s(2)])
    }

    @Test func fadeThroughTimelineIsOneReplace() throws {
        var t = Track(kind: .video)
        let c = videoClip(dur: 5)
        try t.overwrite(c)
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [t])
        try tl.fadeVideo([c.id], edge: .head, duration: s(1))
        #expect(tl.tracks[0].clips[0].animation.opacity.track.keys.count == 2)
        #expect(tl.tracks[0].clips[0].transform(at: s(0)).opacity == 0)
    }

    @Test func audioClipIsRefused() throws {
        var t = Track(kind: .audio)
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(5)), start: .zero)
        try t.overwrite(a)
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [t])
        #expect(throws: EditError.self) { var t2 = tl; try t2.fadeVideo([a.id], edge: .head, duration: s(1)) }
    }
}

@Suite struct OpacityKeyTests {
    @Test func keyAtTimeTakesCurrentInterpolatedValue() {
        var c = videoClip(dur: 4)
        c.animation.opacity = AnimatedProperty(1.0, track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: 0.0), Keyframe(time: s(4), value: 1.0)]))
        let id = c.addOpacityKey(atLocal: s(2))
        #expect(id != nil)
        let k = c.animation.opacity.track.keys.first { $0.id == id }!
        #expect(k.time == s(2))
        #expect(abs(k.value - 0.5) < 1e-9)
        #expect(c.animation.opacity.track.keys.count == 3)
    }

    @Test func staticOpacityStartsTheTrackWithOneKey() {
        var c = videoClip(dur: 4)
        c.animation.opacity = AnimatedProperty(0.8)
        _ = c.addOpacityKey(atLocal: s(1))
        #expect(c.animation.opacity.track.keys.map(\.value) == [0.8])
    }

    @Test func outsideTheClipIsRefused() {
        var c = videoClip(dur: 4)
        let r8 = c.addOpacityKey(atLocal: s(9))
        #expect(r8 == nil)
        let r9 = c.addOpacityKey(atLocal: s(-1))
        #expect(r9 == nil)
    }
}

@Suite struct PasteAttributesTests {
    private func keyed(_ v: Double, at t: Int64) -> AnimatedProperty<Double> {
        AnimatedProperty(1.0, track: KeyframeTrack(keys: [Keyframe(time: s(t), value: v)]))
    }

    @Test func motionOpacityReplaceEffectsAreAdded() {
        var src = videoClip(start: 0, dur: 5)
        src.animation.rotation = keyed(45, at: 1)
        src.animation.opacity = keyed(0.5, at: 2)
        src.animation.scale = AnimatedProperty(Vec2(2, 2))
        src.blendMode = .screen
        _ = src.addEffect(kind: ClipEffect.gaussianBlurKind)
        var dst = videoClip(start: 20, dur: 8)
        dst.animation.position = AnimatedProperty(Vec2(30, 40))
        let existing = dst.addEffect(kind: ClipEffect.cropKind)!
        let out = dst.pastingAttributes(from: src)
        #expect(out.animation.rotation.track.keys.map(\.time) == [s(1)])      // clip-local: same offset into the target
        #expect(out.animation.opacity.track.keys.map(\.value) == [0.5])
        #expect(out.animation.scale.value == Vec2(2, 2))
        #expect(out.animation.position.value == .zero)                         // replaced by the source's (default) motion
        #expect(out.blendMode == .screen)
        #expect(out.effects.count == 2)
        #expect(out.effects[0].id == existing)                                 // existing effects stay first
        #expect(out.effects[1].kind == ClipEffect.gaussianBlurKind)
        #expect(!src.effects.contains { $0.id == out.effects[1].id })          // pasted copies have fresh ids
        #expect(out.start == dst.start && out.source == dst.source && out.id == dst.id)
    }

    @Test func keysAreNotShiftedByWhereTheClipsSit() {
        var src = videoClip(start: 100, dur: 5)
        src.animation.opacity = keyed(0.2, at: 3)
        let dst = videoClip(start: 7, dur: 9)
        #expect(dst.pastingAttributes(from: src).animation.opacity.track.keys.map(\.time) == [s(3)])
    }

    @Test func volumeAndGainOnlyForAudio() {
        var src = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(5)), start: .zero)
        src.animation.volume = AnimatedProperty(0.5)
        src.audioGainDB = 6
        let dst = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(5)), start: s(9))
        let out = dst.pastingAttributes(from: src)
        #expect(out.animation.volume.value == 0.5 && out.audioGainDB == 6)
        // A video clip never takes the audio volume.
        let v = videoClip().pastingAttributes(from: src)
        #expect(v.animation.volume.value == 1)
    }

    @Test func timelineApplyIsOneStepAndSkipsSource() throws {
        var src = videoClip(start: 0, dur: 5)
        src.animation.rotation = AnimatedProperty(90.0)
        let dst = videoClip(start: 5, dur: 5)
        var t = Track(kind: .video)
        try t.overwrite(src); try t.overwrite(dst)
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [t])
        let n = try tl.pasteAttributes(from: src, to: [src.id, dst.id])
        #expect(n == 1)
        #expect(tl.tracks[0].clips[1].animation.rotation.value == 90)
    }
}

@Suite struct FrameHoldTests {
    private func timeline(_ clip: Clip, linkedAudio: Clip? = nil) throws -> Timeline {
        var v = Track(kind: .video)
        try v.overwrite(clip)
        var tracks = [v]
        if let a = linkedAudio {
            var at = Track(kind: .audio)
            try at.overwrite(a)
            tracks.append(at)
        }
        return Timeline(name: "t", frameDuration: fd, tracks: tracks)
    }

    @Test func heldClipShowsOneSourceFrameAtEveryTime() {
        var c = videoClip(start: 0, dur: 4)
        c.holdFrame = s(12)
        for t in [Int64(0), 1, 2, 3] { #expect(c.sourceTime(at: s(t), frameDuration: fd) == s(12)) }
        #expect(c.sourceTime(at: Time(7, 2), frameDuration: fd) == s(12))
    }

    @Test func insertFrameHoldSplitsAndInsertsRequestedDuration() throws {
        let c = videoClip(start: 0, dur: 10)          // source 10...20
        var tl = try timeline(c)
        try tl.tracks[0].overwrite(videoClip(start: 10, dur: 2))
        let hold = try tl.insertFrameHold(at: s(4), duration: s(2))
        let clips = tl.tracks[0].clips
        #expect(clips.count == 4)
        #expect(clips[0].timeline == TimeRange(start: s(0), duration: s(4)))
        #expect(clips[1].id == hold)
        #expect(clips[1].timeline == TimeRange(start: s(4), duration: s(2)))
        #expect(clips[1].holdFrame == s(14))           // source start 10 + 4 s into the clip
        #expect(clips[2].timeline.start == s(6))
        #expect(clips[2].source.start == s(14))        // the right half continues where the split happened
        #expect(clips[3].start == s(12))               // later clips rippled by 2 s
        #expect(clips[1].sourceTime(at: s(5), frameDuration: fd) == s(14))
    }

    @Test func insertFrameHoldDurationIsRational() throws {
        var tl = try timeline(videoClip(start: 0, dur: 10))
        let hold = try tl.insertFrameHold(at: s(4), duration: Time(1001, 30000))
        #expect(tl.tracks[0].clips.first { $0.id == hold }!.timeline.duration == Time(1001, 30000))
    }

    @Test func addFrameHoldFreezesTheRestOfTheClip() throws {
        var tl = try timeline(videoClip(start: 0, dur: 10))
        let hold = try tl.addFrameHold(at: s(4))
        let clips = tl.tracks[0].clips
        #expect(clips.count == 2)
        #expect(clips[0].timeline == TimeRange(start: s(0), duration: s(4)))
        #expect(clips[1].id == hold)
        #expect(clips[1].timeline == TimeRange(start: s(4), duration: s(6)))   // same overall length, nothing ripples
        #expect(clips[1].holdFrame == s(14))
    }

    @Test func holdOutsideAClipIsRefused() throws {
        var tl = try timeline(videoClip(start: 0, dur: 4))
        #expect(throws: EditError.self) { var t2 = tl; try t2.insertFrameHold(at: s(9), duration: s(2)) }
        #expect(throws: EditError.self) { var t2 = tl; try t2.addFrameHold(at: s(9)) }
    }

    @Test func holdOnAudioClipIsRefused() throws {
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(5)), start: .zero)
        var t = Track(kind: .audio)
        try t.overwrite(a)
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [t])
        #expect(throws: EditError.self) { var t2 = tl; try t2.insertFrameHold(at: s(1), duration: s(2)) }
    }

    @Test func heldClipTrimsFreelyAndKeepsItsFrame() throws {
        var tl = try timeline(videoClip(start: 0, dur: 10))
        let hold = try tl.addFrameHold(at: s(4))
        _ = try tl.trim(hold, edge: .tail, by: s(5))      // far beyond the media: a still has no media limit
        let h = tl.tracks[0].clips.first { $0.id == hold }!
        #expect(h.timeline.duration == s(11))
        #expect(h.sourceTime(at: s(12), frameDuration: fd) == s(14))
    }

    @Test func holdRoundTripsThroughJSON() throws {
        var c = videoClip()
        c.holdFrame = Time(1001, 30000)
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        #expect(back.holdFrame == Time(1001, 30000))
        #expect(try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(videoClip())).holdFrame == nil)
    }
}

@Suite struct ProjectFileV22Tests {
    @Test func v21ProjectWithoutNewFieldsDecodes() throws {
        let c = videoClip()
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c])])
        let project = Project(name: "P", timelines: [tl])
        let data = try ProjectFile.encode(project)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["formatVersion"] = 21
        let old = try JSONSerialization.data(withJSONObject: obj)
        let back = try ProjectFile.decode(old, migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].clips[0].blendMode == .normal)
        #expect(back.timelines[0].tracks[0].clips[0].holdFrame == nil)
    }

    @Test func v22RoundTripKeepsBlendHoldAndEffectOrder() throws {
        var c = videoClip()
        c.blendMode = .overlay
        c.holdFrame = s(3)
        let a = c.addEffect(kind: ClipEffect.gaussianBlurKind)!
        let b = c.addEffect(kind: ClipEffect.gaussianBlurKind)!
        _ = c.moveEffect(b, to: 0)
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c])])
        let data = try ProjectFile.encode(Project(name: "P", timelines: [tl]))
        let back = try ProjectFile.decode(data, migrations: ProjectFile.migrations).timelines[0].tracks[0].clips[0]
        #expect(back.blendMode == .overlay && back.holdFrame == s(3))
        #expect(back.effects.map(\.id) == [b, a])
        #expect(ProjectFile.currentVersion >= 22)
    }
}
