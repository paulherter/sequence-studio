import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

private func fr(_ n: Int64) -> Time { Time(n, 30) }

/// Key drag in the Effect Controls lanes: measured per step, and the one-undo-step contract.
@MainActor @Suite struct EffectControlsDragTests {
    /// A session with `clips` clips on one track; the first one has `keys` keys on Scale and Position, selected.
    private func rig(clips: Int = 200, keys: Int = 20) throws -> (EditorSession, EffectControlsModel, Clip) {
        var track = Track(kind: .video)
        var first: Clip?
        for i in 0..<clips {
            var c = Clip(name: "c\(i)", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(60, 1)), start: Time(Int64(i) * 60, 1))
            if i == 0 {
                c.animation.scale.track = KeyframeTrack(keys: (0..<keys).map { Keyframe(time: fr(Int64($0) * 30), value: Vec2(1, 1)) })
                c.animation.position.track = KeyframeTrack(keys: (0..<keys).map { Keyframe(time: fr(Int64($0) * 30), value: Vec2(Double($0), 0)) })
                first = c
            }
            try track.overwrite(c)
        }
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [track])
        let session = EditorSession(project: Project(name: "P", timelines: [t]))
        let model = EffectControlsModel()
        session.onChange = { [unowned session] c in model.sync(with: session, change: c) }
        model.onEdit = { c, name, co in session.replaceDisplayedClip(c, name: name, continuesGesture: co) }
        session.select(clips: [first!.id])
        return (session, model, first!)
    }

    private func selectAll(_ m: EffectControlsModel) {
        let c = m.clip!
        m.select(c.animation.scale.track.keys.map { SummaryMember(property: EffectProperty.scale.id, keyID: $0.id) }, extend: false)
    }

    @Test func dragStepCost() throws {
        let (session, m, _) = try rig()
        selectAll(m)
        let steps = 60
        let clock = ContinuousClock()
        let d = clock.measure {
            m.beginGesture()
            for i in 1...steps { m.moveSelection(by: fr(Int64(i % 8))) }
            m.endKeyMove()
        }
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        print(String(format: "PERF key drag (200 clips, 20 keys, 2 props): %.3f ms/step", ms / Double(steps)))
        #expect(ms / Double(steps) < SQTiming.budget(50))
        #expect(session.undoDepth >= 1)
    }

    @Test func dragIsOneUndoStepAndEmitsOnceOnMouseUp() throws {
        let (session, m, original) = try rig(clips: 3, keys: 3)
        selectAll(m)
        let depth = session.undoDepth
        var emitted = 0
        let forward = m.onEdit
        m.onEdit = { c, n, co in emitted += 1; forward?(c, n, co) }
        m.beginGesture()
        m.moveSelection(by: fr(2)); m.moveSelection(by: fr(4)); m.moveSelection(by: fr(5))
        // The lanes already show the keys at their new place; the session has not been touched yet.
        #expect(m.clip!.animation.scale.track.keys[0].time == fr(5))
        #expect(emitted == 0)
        m.endKeyMove()
        #expect(emitted == 1)
        #expect(session.undoDepth == depth + 1)
        #expect(session.displayedSelectedClip?.animation.scale.track.keys[0].time == fr(5))
        session.undo()
        #expect(session.displayedSelectedClip?.animation.scale.track.keys[0].time == original.animation.scale.track.keys[0].time)
    }

    @Test func cancellingTheDragEmitsNothing() throws {
        let (session, m, _) = try rig(clips: 3, keys: 3)
        selectAll(m)
        let depth = session.undoDepth
        m.beginGesture()
        m.moveSelection(by: fr(5))
        m.moveSelection(by: .zero)        // Escape: back to the start
        m.endKeyMove()
        #expect(session.undoDepth == depth)
    }

    @Test func aSessionChangeDuringTheDragDoesNotRevertTheKeys() throws {
        let (session, m, _) = try rig(clips: 3, keys: 3)
        selectAll(m)
        m.beginGesture()
        m.moveSelection(by: fr(5))
        session.seek(to: Time(1, 1))
        session.select(clips: session.selection)
        #expect(m.clip!.animation.scale.track.keys[0].time == fr(5))
        m.endKeyMove()
    }

    @Test func aKeyCanBeDraggedPastItsNeighbour() throws {
        let (_, m, _) = try rig(clips: 2, keys: 3)          // keys at 0, 1 s, 2 s
        let first = m.clip!.animation.scale.track.keys[0]
        m.select([SummaryMember(property: EffectProperty.scale.id, keyID: first.id)], extend: false)
        m.beginGesture()
        m.moveSelection(by: fr(45))                          // 1.5 s: behind the key at 1 s
        let keys = m.clip!.animation.scale.track.keys
        #expect(keys.count == 3 && keys.map(\.time) == [fr(30), fr(45), fr(60)] && keys[1].id == first.id)
        m.moveSelection(by: fr(30))                          // exactly onto the key at 1 s: one frame further, no merge
        #expect(m.clip!.animation.scale.track.keys.map(\.time) == [fr(30), fr(31), fr(60)])
        m.endKeyMove()
    }
}
