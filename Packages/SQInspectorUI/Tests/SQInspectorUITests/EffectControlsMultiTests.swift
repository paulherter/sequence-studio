import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// Multi-select editing: several clips selected, Effect Controls shows the first and edits all of them.
@MainActor @Suite struct EffectControlsMultiTests {
    @MainActor private struct Rig {
        let session: EditorSession
        let model: EffectControlsModel
        let v: Clip, a: Clip, o: Clip, w: Clip, audioOnly: Clip
        func clip(_ id: Clip.ID) -> Clip? { session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id } }
    }

    /// V1: v (0-2 s, linked to a), o (2-4 s). V2: w (1-5 s). A1: a (0-2 s), audioOnly (3-5 s).
    private func rig(blurOn: Bool = false) throws -> Rig {
        let link = UUID()
        func clip(_ n: String, _ k: TrackKind, _ start: Int64, _ d: Int64, link: UUID? = nil) -> Clip {
            Clip(name: n, media: UUID(), kind: k, source: TimeRange(start: .zero, duration: s(d)), start: s(start), link: link)
        }
        var v = clip("v", .video, 0, 2, link: link), o = clip("o", .video, 2, 2), w = clip("w", .video, 1, 4)
        let a = clip("a", .audio, 0, 2, link: link), ao = clip("ao", .audio, 3, 2)
        if blurOn {
            v.effects = [ClipEffect(kind: ClipEffect.gaussianBlurKind, parameters: [ClipEffect.blurrinessKey: AnimatedProperty(10)])]
            o.effects = [ClipEffect(kind: ClipEffect.cropKind),
                         ClipEffect(kind: ClipEffect.gaussianBlurKind, parameters: [ClipEffect.blurrinessKey: AnimatedProperty(10)])]
        }
        var v1 = Track(kind: .video), v2 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(v); try v1.overwrite(o); try v2.overwrite(w); try a1.overwrite(a); try a1.overwrite(ao)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v1, v2, a1])
        let session = EditorSession(project: Project(name: "P", timelines: [t]))
        let model = EffectControlsModel()
        session.onChange = { [unowned session] c in model.sync(with: session, change: c) }
        model.onEdit = { c, name, co in session.replaceDisplayedClip(c, name: name, continuesGesture: co) }
        model.onEditMany = { cs, name, co in session.replaceDisplayedClips(cs, name: name, continuesGesture: co) }
        return Rig(session: session, model: model, v: v, a: a, o: o, w: w, audioOnly: ao)
    }

    // MARK: Selection

    @Test func severalClipsShowTheFirstAndEditTheRest() throws {
        let r = try rig()
        r.session.select(clips: [r.o.id, r.w.id])
        #expect(r.model.clip?.id == r.w.id)                 // earliest start first
        #expect(r.model.peers.map(\.id) == [r.o.id])
        #expect(r.model.isMulti)
        // A linked pair counts once, by its video clip.
        r.session.select(clips: [r.v.id, r.a.id, r.o.id])
        #expect(r.model.clip?.id == r.v.id && r.model.peers.map(\.id) == [r.o.id])
        // Picture and sound-only clips together: nothing to edit in common.
        r.session.select(clips: [r.o.id, r.audioOnly.id])
        #expect(r.model.clip == nil && !r.model.isMulti)
        // One clip again: no peers.
        r.session.select(clips: [r.o.id])
        #expect(r.model.clip?.id == r.o.id && !r.model.isMulti)
    }

    @Test func multiShowsOnlySectionsAllClipsShare() throws {
        let r = try rig(blurOn: true)
        r.session.select(clips: [r.v.id, r.o.id])
        let blur = r.model.clip!.effects[0]
        #expect(r.model.visibleSections == [.motion, .effect(blur.id, kind: blur.kind)])   // no Crop (only o), no Speed, no Audio
        r.session.select(clips: [r.v.id, r.w.id])
        #expect(r.model.visibleSections == [.motion])
    }

    // MARK: Equal / mixed values

    @Test func equalValuesShowDifferingValuesAreMixed() throws {
        let r = try rig()
        r.session.select(clips: [r.o.id, r.w.id])
        #expect(!r.model.isMixed(.opacity))
        var o = r.clip(r.o.id)!; o.animation.position.value = Vec2(100, 0)
        r.session.replaceClip(o, name: "x", continuesGesture: false)
        #expect(r.model.isMixed(.position, component: .x))
        #expect(!r.model.isMixed(.position, component: .y))
        #expect(r.model.isMixed(.position))
    }

    @Test func mixedComparesEachClipAtItsOwnLocalTime() throws {
        let r = try rig()
        // w (starts 1 s) keyed 0 -> 1 over its first 2 s; o (starts 2 s) static 0.5. Playhead at 2 s: w is at 0.5 too.
        var w = r.clip(r.w.id)!
        w.animation.opacity.track.insert(Keyframe(time: .zero, value: 0))
        w.animation.opacity.track.insert(Keyframe(time: s(2), value: 1))
        var o = r.clip(r.o.id)!; o.animation.opacity.value = 0.5
        r.session.replaceClip(w, name: "x", continuesGesture: false)
        r.session.replaceClip(o, name: "x", continuesGesture: false)
        r.session.select(clips: [r.o.id, r.w.id])
        r.session.seek(to: s(2))
        #expect(!r.model.isMixed(.opacity))
        r.session.seek(to: s(3))
        #expect(r.model.isMixed(.opacity))
    }

    // MARK: Edits

    @Test func editSetsAllClipsInOneUndoStep() throws {
        let r = try rig()
        r.session.select(clips: [r.o.id, r.w.id])
        #expect(r.model.setValue(.opacity, to: 0.25))
        #expect(r.clip(r.o.id)?.animation.opacity.value == 0.25)
        #expect(r.clip(r.w.id)?.animation.opacity.value == 0.25)
        #expect(!r.model.isMixed(.opacity))
        r.session.undo()
        #expect(r.clip(r.o.id)?.animation.opacity.value == 1)
        #expect(r.clip(r.w.id)?.animation.opacity.value == 1)
    }

    @Test func oneComponentKeepsEachClipsOtherComponent() throws {
        let r = try rig()
        var o = r.clip(r.o.id)!; o.animation.position.value = Vec2(10, 20)
        var w = r.clip(r.w.id)!; w.animation.position.value = Vec2(30, 40)
        r.session.replaceClip(o, name: "x", continuesGesture: false)
        r.session.replaceClip(w, name: "x", continuesGesture: false)
        r.session.select(clips: [r.o.id, r.w.id])
        #expect(r.model.setValue(.position, component: .x, to: 5))
        #expect(r.clip(r.o.id)?.animation.position.value == Vec2(5, 20))
        #expect(r.clip(r.w.id)?.animation.position.value == Vec2(5, 40))
    }

    @Test func gestureIsOneUndoStepAndDoesNotAccumulate() throws {
        let r = try rig()
        r.session.select(clips: [r.o.id, r.w.id])
        r.model.beginGesture()
        r.model.setValue(.rotation, to: 10)
        r.model.setValue(.rotation, to: 20)
        r.model.setValue(.rotation, to: 30)
        r.model.endGesture()
        #expect(r.clip(r.o.id)?.animation.rotation.value == 30)
        #expect(r.clip(r.w.id)?.animation.rotation.value == 30)
        r.session.undo()
        #expect(r.clip(r.o.id)?.animation.rotation.value == 0)
        #expect(r.clip(r.w.id)?.animation.rotation.value == 0)
    }

    @Test func animatedPeerGetsAKeyAtItsOwnPlayhead() throws {
        let r = try rig()
        var w = r.clip(r.w.id)!
        w.animation.opacity.track.insert(Keyframe(time: .zero, value: 1))
        r.session.replaceClip(w, name: "x", continuesGesture: false)
        r.session.select(clips: [r.o.id, r.w.id])
        r.session.seek(to: s(3))
        #expect(r.model.setValue(.opacity, to: 0.5))
        #expect(r.clip(r.o.id)?.animation.opacity.value == 0.5)                 // static: the value
        let keys = r.clip(r.w.id)!.animation.opacity.track.keys
        #expect(keys.contains { $0.time == s(2) && $0.value == 0.5 })          // 3 s on the timeline = 2 s into w
    }

    @Test func effectParameterGoesToTheMatchingEffect() throws {
        let r = try rig(blurOn: true)
        r.session.select(clips: [r.v.id, r.o.id])
        let blur = r.model.clip!.effects[0]
        let p = EffectProperty.fx(blur.id, kind: blur.kind, key: ClipEffect.blurrinessKey)
        #expect(!r.model.isMixed(p))
        #expect(r.model.setValue(p, to: 40))
        #expect(r.clip(r.v.id)?.effects[0].parameters[ClipEffect.blurrinessKey]?.value == 40)
        #expect(r.clip(r.o.id)?.effects[1].parameters[ClipEffect.blurrinessKey]?.value == 40)
        #expect(r.clip(r.o.id)?.effects[0].parameters[ClipEffect.blurrinessKey] == nil)   // Crop untouched
    }

    @Test func resetResetsAllClips() throws {
        let r = try rig()
        r.session.select(clips: [r.o.id, r.w.id])
        r.model.setValue(.rotation, to: 45)
        r.model.resetAll(.rotation)
        #expect(r.clip(r.o.id)?.animation.rotation.value == 0)
        #expect(r.clip(r.w.id)?.animation.rotation.value == 0)
    }
}
