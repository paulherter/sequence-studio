import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// Transform shows Crop rows (Left, Right, Top, Bottom, Softness) that ARE the clip's first Crop effect: one system, no
/// second crop. A clip without a Crop gets one on the first edit of a row.
@MainActor @Suite struct TransformCropRowsTests {
    @MainActor private struct Rig {
        let session: EditorSession
        let model: EffectControlsModel
        let a: Clip, b: Clip, sound: Clip
        func clip(_ id: Clip.ID) -> Clip? { session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id } }
    }

    /// V1: a (0-2 s), b (2-4 s). A1: sound (0-2 s).
    private func rig(_ configure: (inout Clip, inout Clip) -> Void = { _, _ in }) throws -> Rig {
        func clip(_ n: String, _ k: TrackKind, _ start: Int64) -> Clip {
            Clip(name: n, media: UUID(), kind: k, source: TimeRange(start: .zero, duration: s(2)), start: s(start))
        }
        var a = clip("a", .video, 0), b = clip("b", .video, 2)
        let sound = clip("s", .audio, 0)
        configure(&a, &b)
        var v1 = Track(kind: .video), a1 = Track(kind: .audio)
        try v1.overwrite(a); try v1.overwrite(b); try a1.overwrite(sound)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v1, a1])
        let session = EditorSession(project: Project(name: "P", timelines: [t]))
        let model = EffectControlsModel()
        session.onChange = { [unowned session] c in model.sync(with: session, change: c) }
        model.onEdit = { c, name, co in session.replaceDisplayedClip(c, name: name, continuesGesture: co) }
        model.onEditMany = { cs, name, co in session.replaceDisplayedClips(cs, name: name, continuesGesture: co) }
        return Rig(session: session, model: model, a: a, b: b, sound: sound)
    }

    private func crops(_ c: Clip?) -> [ClipEffect] { c?.effects.filter { $0.kind == ClipEffect.cropKind } ?? [] }

    @Test func transformListsFiveCropRowsAfterItsOwn() throws {
        let r = try rig()
        r.session.select(clips: [r.a.id])
        let crop = r.model.transformCropProperties
        #expect(crop.map(\.title) == ["Left", "Right", "Top", "Bottom", "Softness"])
        #expect(r.model.properties(of: .motion) == EffectSection.motion.properties + crop)
        #expect(crop.allSatisfy { r.model.scalarValue($0) == 0 && !r.model.isAnimated($0) })
        let rows = EffectControlsLayout.rows(sections: [.motion], collapsed: [], expanded: [], transformCrop: crop)
        let props = rows.compactMap { if case .property(let p) = $0.kind { p } else { nil } }
        #expect(Array(props.suffix(5)) == crop)
        // Sound clips have no picture to crop.
        r.session.select(clips: [r.sound.id])
        #expect(r.model.transformCropProperties.isEmpty)
    }

    @Test func firstEditAddsTheCropEffectOnce() throws {
        let r = try rig()
        r.session.select(clips: [r.a.id])
        #expect(crops(r.clip(r.a.id)).isEmpty)                           // just showing the rows changes nothing
        let left = r.model.transformCropProperties[0]
        #expect(r.model.setValue(left, to: 20))
        #expect(crops(r.clip(r.a.id)).count == 1)
        #expect(r.clip(r.a.id)!.effects(at: s(1)).pre.crop.left == 0.2)
        let soft = r.model.transformCropProperties[4]
        #expect(r.model.setValue(soft, to: 6))
        #expect(crops(r.clip(r.a.id)).count == 1)                        // the same Crop, never a second one
        #expect(r.clip(r.a.id)!.effects(at: s(1)).pre.feather == 6)
        r.session.undo(); r.session.undo()
        #expect(crops(r.clip(r.a.id)).isEmpty)                           // the add is part of the first edit's undo step
    }

    @Test func resetOnAMissingCropAddsNothing() throws {
        let r = try rig()
        r.session.select(clips: [r.a.id])
        r.model.resetAll(r.model.transformCropProperties[0])
        #expect(crops(r.clip(r.a.id)).isEmpty)
    }

    @Test func existingCropIsShownInTransformNotAsItsOwnSection() throws {
        var cropID = UUID()
        let r = try rig { a, _ in
            cropID = a.addEffect(kind: ClipEffect.cropKind)!
            a.setParameter(cropID, ClipEffect.cropTopKey, to: 30)
            a.effects[0].parameters[ClipEffect.cropSoftnessKey] = nil     // saved before Softness existed
        }
        r.session.select(clips: [r.a.id])
        #expect(r.model.visibleSections.contains(.motion) && !r.model.visibleSections.contains { $0.effectKind != nil })
        let crop = r.model.transformCropProperties
        #expect(crop.allSatisfy { if case .fx(let id, _, _) = $0 { id == cropID } else { false } })
        #expect(r.model.scalarValue(crop[2]) == 30)
        #expect(r.model.setValue(crop[4], to: 3))                       // an old Crop takes Softness too
        #expect(r.clip(r.a.id)!.effects(at: s(1)).pre.feather == 3)
        #expect(crops(r.clip(r.a.id)).count == 1)
    }

    @Test func aSecondCropKeepsItsOwnSection() throws {
        var ids: [UUID] = []
        let r = try rig { a, _ in ids = [a.addEffect(kind: ClipEffect.cropKind)!, a.addEffect(kind: ClipEffect.cropKind)!] }
        r.session.select(clips: [r.a.id])
        #expect(r.model.visibleSections.filter { $0.effectKind != nil } == [.effect(ids[1], kind: ClipEffect.cropKind)])
    }

    @Test func stopwatchOnAMissingCropAddsItWithAKey() throws {
        let r = try rig()
        r.session.select(clips: [r.a.id])
        r.session.seek(to: s(1))
        let right = r.model.transformCropProperties[1]
        #expect(r.model.toggleStopwatch(right) == .added)
        let e = crops(r.clip(r.a.id))
        #expect(e.count == 1 && e[0].parameters[ClipEffect.cropRightKey]?.track.keys.map(\.time) == [s(1)])
        #expect(r.model.isAnimated(r.model.transformCropProperties[1]))
    }

    @Test func multiSelectCropsEveryClipInOneStep() throws {
        var cropID = UUID()
        let r = try rig { a, _ in cropID = a.addEffect(kind: ClipEffect.cropKind)! }
        r.session.select(clips: [r.a.id, r.b.id])
        #expect(r.model.isMulti)
        let bottom = r.model.transformCropProperties[3]
        #expect(!r.model.isMixed(bottom))                                // 0 on a, no Crop (= 0) on b
        #expect(r.model.setValue(bottom, to: 25))
        #expect(r.clip(r.a.id)!.effects.first { $0.id == cropID }?.parameters[ClipEffect.cropBottomKey]?.value == 25)
        #expect(crops(r.clip(r.b.id)).count == 1)                        // b gets its Crop
        #expect(r.clip(r.b.id)!.effects(at: s(3)).pre.crop.bottom == 0.25)
        r.session.undo()
        #expect(crops(r.clip(r.b.id)).isEmpty)
        #expect(r.clip(r.a.id)!.effects.first { $0.id == cropID }?.parameters[ClipEffect.cropBottomKey]?.value == 0)
    }
}
