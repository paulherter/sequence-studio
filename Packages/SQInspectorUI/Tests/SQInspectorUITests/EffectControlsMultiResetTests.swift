import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// Multi-select: Reset (at the playhead and whole sections), the fx switch and Blend Mode act on every selected clip in
/// one undo step; a differing Blend Mode shows as mixed.
@MainActor @Suite struct EffectControlsMultiResetTests {
    @MainActor private struct Rig {
        let session: EditorSession
        let model: EffectControlsModel
        let o: Clip.ID, w: Clip.ID
        func clip(_ id: Clip.ID) -> Clip { session.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }! }
        func replace(_ c: Clip) { session.replaceClip(c, name: "x", continuesGesture: false) }
    }

    /// V1: o (2-4 s). V2: w (1-5 s). Both with one Gaussian Blur (blurriness 10) when `blur`.
    private func rig(blur: Bool = false) throws -> Rig {
        func clip(_ n: String, _ start: Int64, _ d: Int64) -> Clip {
            var c = Clip(name: n, media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(d)), start: s(start))
            if blur {
                c.effects = [ClipEffect(kind: ClipEffect.gaussianBlurKind, parameters: [ClipEffect.blurrinessKey: AnimatedProperty(10)])]
            }
            return c
        }
        let o = clip("o", 2, 2), w = clip("w", 1, 4)
        var v1 = Track(kind: .video), v2 = Track(kind: .video)
        try v1.overwrite(o); try v2.overwrite(w)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v1, v2])
        let session = EditorSession(project: Project(name: "P", timelines: [t]))
        let model = EffectControlsModel()
        session.onChange = { [unowned session] c in model.sync(with: session, change: c) }
        model.onEdit = { c, name, co in session.replaceDisplayedClip(c, name: name, continuesGesture: co) }
        model.onEditMany = { cs, name, co in session.replaceDisplayedClips(cs, name: name, continuesGesture: co) }
        return Rig(session: session, model: model, o: o.id, w: w.id)
    }

    @Test func resetAtPlayheadKeysEveryClipAtItsOwnPlayhead() throws {
        let r = try rig()
        var w = r.clip(r.w)
        w.animation.rotation.track.insert(Keyframe(time: .zero, value: 30))
        w.animation.rotation.track.insert(Keyframe(time: s(4), value: 90))
        var o = r.clip(r.o)
        o.animation.rotation.track.insert(Keyframe(time: .zero, value: 45))
        r.replace(w); r.replace(o)
        r.session.select(clips: [r.o, r.w])
        r.session.seek(to: s(3))
        #expect(r.model.clip?.id == r.w)
        #expect(r.model.resetAtPlayhead(.rotation))
        // 3 s on the timeline = 2 s into w, 1 s into o.
        #expect(r.clip(r.w).animation.rotation.track.keys.contains { $0.time == s(2) && $0.value == 0 })
        #expect(r.clip(r.o).animation.rotation.track.keys.contains { $0.time == s(1) && $0.value == 0 })
        r.session.undo()
        #expect(r.clip(r.w).animation.rotation.track.keys.count == 2)
        #expect(r.clip(r.o).animation.rotation.track.keys.count == 1)
    }

    @Test func resetAtPlayheadSetsAStaticPeer() throws {
        let r = try rig()
        var w = r.clip(r.w)
        w.animation.opacity.track.insert(Keyframe(time: .zero, value: 0.2))
        var o = r.clip(r.o); o.animation.opacity.value = 0.4
        r.replace(w); r.replace(o)
        r.session.select(clips: [r.o, r.w])
        r.session.seek(to: s(3))
        #expect(r.model.resetAtPlayhead(.opacity))
        #expect(r.clip(r.o).animation.opacity.value == 1)
        #expect(!r.clip(r.o).animation.opacity.isAnimated)
    }

    @Test func resetSectionResetsTheMatchingSectionOnAllClips() throws {
        let r = try rig(blur: true)
        r.session.select(clips: [r.o, r.w])
        let blur = r.model.clip!.effects[0]
        let p = EffectProperty.fx(blur.id, kind: blur.kind, key: ClipEffect.blurrinessKey)
        #expect(r.model.setValue(p, to: 40))
        r.model.setValue(.rotation, to: 12)
        r.model.resetSection(.effect(blur.id, kind: blur.kind))
        let def = EffectCatalog.param(blur.kind, ClipEffect.blurrinessKey)?.defaultValue
        #expect(r.clip(r.w).effects[0].parameters[ClipEffect.blurrinessKey]?.value == def)
        #expect(r.clip(r.o).effects[0].parameters[ClipEffect.blurrinessKey]?.value == def)
        r.model.resetSection(.motion)
        #expect(r.clip(r.w).animation.rotation.value == 0)
        #expect(r.clip(r.o).animation.rotation.value == 0)
        r.session.undo()
        #expect(r.clip(r.w).animation.rotation.value == 12)
        #expect(r.clip(r.o).animation.rotation.value == 12)
    }

    @Test func fxSwitchTurnsTheEffectOffOnAllClipsInOneStep() throws {
        let r = try rig(blur: true)
        r.session.select(clips: [r.o, r.w])
        let blur = r.model.clip!.effects[0]
        let sec = EffectSection.effect(blur.id, kind: blur.kind)
        r.model.setEffectEnabled(sec, false)
        #expect(r.clip(r.w).effects[0].enabled == false)
        #expect(r.clip(r.o).effects[0].enabled == false)
        r.session.undo()
        #expect(r.clip(r.w).effects[0].enabled && r.clip(r.o).effects[0].enabled)
        // Motion's switch too.
        r.model.setEffectEnabled(.motion, false)
        #expect(!r.clip(r.w).motionEnabled && !r.clip(r.o).motionEnabled)
    }

    @Test func fxSwitchShowsMixedWhenClipsDiffer() throws {
        let r = try rig(blur: true)
        var o = r.clip(r.o); o.effects[0].enabled = false
        r.replace(o)
        r.session.select(clips: [r.o, r.w])
        let blur = r.model.clip!.effects[0]
        let sec = EffectSection.effect(blur.id, kind: blur.kind)
        #expect(r.model.isEffectEnabledMixed(sec))
        #expect(!r.model.isEffectEnabledMixed(.motion))
        // The shown clip is on: the switch turns all of them on (it is shown on, so "off" is the click).
        r.model.setEffectEnabled(sec, true)
        #expect(r.clip(r.o).effects[0].enabled)
        #expect(!r.model.isEffectEnabledMixed(sec))
    }

    @Test func blendModeGoesToAllClipsAndShowsMixed() throws {
        let r = try rig()
        r.session.select(clips: [r.o, r.w])
        #expect(!r.model.isBlendModeMixed)
        r.model.setBlendMode(.multiply)
        #expect(r.clip(r.o).blendMode == .multiply && r.clip(r.w).blendMode == .multiply)
        r.session.undo()
        #expect(r.clip(r.o).blendMode == .normal && r.clip(r.w).blendMode == .normal)
        var o = r.clip(r.o); o.blendMode = .screen
        r.replace(o)
        #expect(r.model.isBlendModeMixed)
        // Mixed: picking the shown clip's own mode still sets it on all.
        r.model.setBlendMode(.normal)
        #expect(r.clip(r.o).blendMode == .normal)
        #expect(!r.model.isBlendModeMixed)
    }
}
