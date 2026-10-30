import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// Multi-select, part 2: the key buttons (stopwatch, add / remove key) act on every selected clip in one undo step, and an
/// effect only some of the selected clips have still shows and edits just those.
@MainActor @Suite struct EffectControlsMultiKeysTests {
    @MainActor private struct Rig {
        let session: EditorSession
        let model: EffectControlsModel
        let x: Clip, y: Clip, z: Clip
        func clip(_ id: Clip.ID) -> Clip? { session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id } }
    }

    /// V1: x (0-4 s). V2: y (2-6 s). V3: z (8-10 s).
    private func rig(blur: (Bool, Bool, Bool) = (false, false, false)) throws -> Rig {
        func clip(_ n: String, _ start: Int64, _ d: Int64, _ withBlur: Bool) -> Clip {
            var c = Clip(name: n, media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(d)), start: s(start))
            if withBlur {
                c.effects = [ClipEffect(kind: ClipEffect.gaussianBlurKind, parameters: [ClipEffect.blurrinessKey: AnimatedProperty(10)])]
            }
            return c
        }
        let x = clip("x", 0, 4, blur.0), y = clip("y", 2, 4, blur.1), z = clip("z", 8, 2, blur.2)
        var v1 = Track(kind: .video), v2 = Track(kind: .video), v3 = Track(kind: .video)
        try v1.overwrite(x); try v2.overwrite(y); try v3.overwrite(z)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v1, v2, v3])
        let session = EditorSession(project: Project(name: "P", timelines: [t]))
        let model = EffectControlsModel()
        session.onChange = { [unowned session] c in model.sync(with: session, change: c) }
        model.onEdit = { c, name, co in session.replaceDisplayedClip(c, name: name, continuesGesture: co) }
        model.onEditMany = { cs, name, co in session.replaceDisplayedClips(cs, name: name, continuesGesture: co) }
        return Rig(session: session, model: model, x: x, y: y, z: z)
    }

    private func keyTimes(_ c: Clip?) -> [Time] { c?.animation.rotation.track.keys.map(\.time) ?? [] }

    @Test func stopwatchKeysEveryClipAtItsOwnPlayheadInOneStep() throws {
        let r = try rig()
        r.session.select(clips: [r.x.id, r.y.id, r.z.id])
        r.session.seek(to: s(3))
        #expect(r.model.toggleStopwatch(.rotation) == .added)
        #expect(keyTimes(r.clip(r.x.id)) == [s(3)])
        #expect(keyTimes(r.clip(r.y.id)) == [s(1)])               // 3 s on the timeline = 1 s into y
        #expect(keyTimes(r.clip(r.z.id)) == [.zero])              // playhead before z: keyed at its nearest end
        r.session.undo()
        #expect([r.x, r.y, r.z].allSatisfy { keyTimes(r.clip($0.id)).isEmpty })
    }

    @Test func stopwatchOffClearsEveryClipAfterConfirmation() throws {
        let r = try rig()
        r.session.select(clips: [r.x.id, r.y.id])
        r.session.seek(to: s(3))
        r.model.toggleStopwatch(.rotation)
        #expect(r.model.toggleStopwatch(.rotation) == .needsConfirmation)
        #expect(r.model.toggleStopwatch(.rotation, confirmRemoval: true) == .removed)
        #expect(keyTimes(r.clip(r.x.id)).isEmpty && keyTimes(r.clip(r.y.id)).isEmpty)
    }

    @Test func addKeyframeCommandNeverRemovesAKey() throws {
        let r = try rig()
        r.session.select(clips: [r.x.id, r.y.id])
        r.session.seek(to: s(3))
        r.model.toggleStopwatch(.rotation)
        r.session.seek(to: s(4))
        #expect(r.model.addKeyAtPlayhead(.rotation) == .added)
        #expect(r.model.addKeyAtPlayhead(.rotation) == .unavailable)
        #expect(keyTimes(r.clip(r.x.id)) == [s(3), s(4)])
    }

    @Test func keyButtonAddsAndRemovesOnEveryClip() throws {
        let r = try rig()
        r.session.select(clips: [r.x.id, r.y.id])
        r.session.seek(to: s(3))
        r.model.toggleStopwatch(.rotation)
        r.session.seek(to: s(4))
        #expect(r.model.toggleKeyAtPlayhead(.rotation) == .added)
        #expect(keyTimes(r.clip(r.x.id)) == [s(3), s(4)])
        #expect(keyTimes(r.clip(r.y.id)) == [s(1), s(2)])
        #expect(r.model.toggleKeyAtPlayhead(.rotation) == .removed)
        #expect(keyTimes(r.clip(r.x.id)) == [s(3)])
        #expect(keyTimes(r.clip(r.y.id)) == [s(1)])
        r.session.undo()
        #expect(keyTimes(r.clip(r.y.id)) == [s(1), s(2)])          // the removal was one step for both
    }

    @Test func anEffectSomeClipsHaveShowsAndEditsOnlyThose() throws {
        let r = try rig(blur: (true, true, false))
        r.session.select(clips: [r.x.id, r.y.id, r.z.id])
        let blur = r.model.clip!.effects[0]
        #expect(r.model.visibleSections == [.motion, .effect(blur.id, kind: blur.kind)])
        let p = EffectProperty.fx(blur.id, kind: blur.kind, key: ClipEffect.blurrinessKey)
        #expect(!r.model.isMixed(p))                               // z has no blur: it is not compared
        #expect(r.model.setValue(p, to: 33))
        #expect(r.clip(r.x.id)?.effects[0].parameters[ClipEffect.blurrinessKey]?.value == 33)
        #expect(r.clip(r.y.id)?.effects[0].parameters[ClipEffect.blurrinessKey]?.value == 33)
        #expect(r.clip(r.z.id)?.effects.isEmpty == true)
        // Only the shown clip has it: nothing to edit together, no section.
        let r2 = try rig(blur: (true, false, false))
        r2.session.select(clips: [r2.x.id, r2.y.id, r2.z.id])
        #expect(r2.model.visibleSections == [.motion])
    }
}
