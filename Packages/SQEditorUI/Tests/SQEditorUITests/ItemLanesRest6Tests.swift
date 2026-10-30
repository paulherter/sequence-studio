import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let step = Time(1, 1_000_000)   // closer to a key than any frame

/// A drag on a timeline line or lane (Opacity, Volume, Item Range) reaches the session as one step that ends once.
@MainActor @Suite struct TimelineLineGestureTests {
    final class Box { var continues: [Bool] = []; var names: [String] = []; var ends = 0 }

    private func rig() -> (TimelineLineGesture, Box, Clip) {
        let box = Box()
        let g = TimelineLineGesture(name: "Opacity", replace: { _, n, c in box.names.append(n); box.continues.append(c) },
                                    end: { box.ends += 1 })
        return (g, box, Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(4)), start: .zero))
    }

    @Test func aDragIsOneStepThatEndsOnce() {
        let (g, box, clip) = rig()
        g.handle(clip, .began); g.handle(clip, .changed); g.handle(clip, .changed)
        #expect(box.continues == [false, true] && box.names == ["Opacity", "Opacity"] && box.ends == 0)
        g.handle(clip, .ended)
        #expect(box.ends == 1)
        g.handle(clip, .ended)
        #expect(box.ends == 1)
        // The next drag starts a step of its own.
        g.handle(clip, .began); g.handle(clip, .changed); g.handle(clip, .ended)
        #expect(box.continues == [false, true, false] && box.ends == 2)
    }

    @Test func aClickThatChangedNothingEndsNothing() {
        let (g, box, clip) = rig()
        g.handle(clip, .began); g.handle(clip, .ended)
        #expect(box.continues.isEmpty && box.ends == 0)
    }

    @Test func aDragWhoseEndWasLostIsEndedByTheNext() {
        let (g, box, clip) = rig()
        g.handle(clip, .began); g.handle(clip, .changed)
        g.handle(clip, .began)
        #expect(box.ends == 1)
        g.handle(clip, .changed); g.handle(clip, .ended)
        #expect(box.continues == [false, false] && box.ends == 2)
    }
}

/// An emitted Effect Controls gesture is ended at the host before its state is dropped.
@MainActor @Suite struct EffectControlsGestureDropTests {
    final class Box { var edits = 0; var ends = 0 }

    private func rig() -> (EffectControlsModel, Box) {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: s(5))
        let m = EffectControlsModel()
        let box = Box()
        m.onEdit = { c, _, _ in box.edits += 1; m.setClip(c) }
        m.onGestureEnded = { box.ends += 1 }
        m.setClip(clip)
        m.playhead = s(5)
        return (m, box)
    }

    @Test func anotherClipEndsTheEmittedGesture() {
        let (m, box) = rig()
        m.beginGesture()
        m.setValue(.opacity, to: 0.5)
        #expect(box.edits == 1 && box.ends == 0)
        m.setClip(Clip(name: "d", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: s(5)))
        #expect(box.ends == 1)
        m.endGesture()      // the late mouse-up
        #expect(box.ends == 1)
    }

    @Test func anotherClipWithoutAnEditEndsNothing() {
        let (m, box) = rig()
        m.beginGesture()
        m.setClip(Clip(name: "d", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: s(5)))
        m.endGesture()
        #expect(box.ends == 0)
    }

    @Test func aSecondBeginEndsTheEmittedGesture() {
        let (m, box) = rig()
        m.beginGesture()
        m.setValue(.opacity, to: 0.5)
        m.beginGesture()
        #expect(box.ends == 1)
        m.setValue(.opacity, to: 0.4)
        m.endGesture()
        #expect(box.edits == 2 && box.ends == 2)
        m.beginGesture(); m.beginGesture(); m.endGesture()
        #expect(box.ends == 2)
    }
}

/// Paste and Option-drag through an X/Y pair row: a Hold Ahead key is one Vec2 key, so its copy is one in both members.
@MainActor @Suite struct PairRowHoldCopyTests {
    private let l = UUID()

    /// X steps ahead from 0.8 to 0.2; Y is a Hold Ahead as well (`flatY`: on one value up to its next key, as a Hold).
    private func setup(flatY: Bool = false) -> (EffectControlsModel, EffectProperty) {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        var e = ClipEffect(kind: ClipEffect.transformKind)
        e.parameters[ClipEffect.stagePositionXKey] = AnimatedProperty(0.0, track: KeyframeTrack(keys: [
            Keyframe(id: l, time: s(2), value: 0.8, interpolation: .holdAhead),
            Keyframe(time: s(6), value: 0.2),
            Keyframe(time: s(8), value: 0.5),
        ]))
        e.parameters[ClipEffect.stagePositionYKey] = AnimatedProperty(0.0, track: KeyframeTrack(keys: [
            Keyframe(time: s(2), value: 10, interpolation: flatY ? .hold : .holdAhead),
            Keyframe(time: s(6), value: flatY ? 10 : 30),
            Keyframe(time: s(8), value: 50),
        ]))
        c.effects.append(e)
        let m = EffectControlsModel()
        m.setClip(c)
        m.playhead = s(4)
        return (m, .fx(e.id, kind: ClipEffect.transformKind, key: ClipEffect.stagePositionXKey))
    }

    private func x(_ m: EffectControlsModel) -> AnimatedProperty<Double> { m.clip!.effects[0].parameters[ClipEffect.stagePositionXKey]! }
    private func y(_ m: EffectControlsModel) -> AnimatedProperty<Double> { m.clip!.effects[0].parameters[ClipEffect.stagePositionYKey]! }

    @Test func aPastedHoldAheadIsOneInBothMembers() {
        for flatY in [false, true] {
            let (m, p) = setup(flatY: flatY)
            m.selectKey(p, id: l, extend: false)
            #expect(m.copyKeys())
            #expect(m.pasteKeys())
            #expect(x(m).track.keys.map(\.time) == [s(2), s(4), s(6), s(8)] && y(m).track.keys.map(\.time) == [s(2), s(4), s(6), s(8)])
            #expect(x(m).track.keys.map(\.interpolation) == [.holdAhead, .holdAhead, .linear, .linear])
            // The copy of (0.8, 10) is the key the first one shows; it steps on to the old next key.
            #expect(x(m).value(atLocal: s(3)) == 0.8 && x(m).value(atLocal: s(5)) == 0.2)
            #expect(y(m).value(atLocal: s(3)) == 10 && y(m).value(atLocal: s(5)) == (flatY ? 10 : 30))
            // The pasted key is the selection, under the id the row shows.
            #expect(m.selection.count == 1)
            #expect(m.selection.first.map { sel in m.keys(p).contains { $0.id == sel.keyID && $0.time == s(4) } } == true)
        }
    }

    @Test func anOptionDragCopyIsOneInBothMembers() {
        for flatY in [false, true] {
            let (m, p) = setup(flatY: flatY)
            m.selectKey(p, id: l, extend: false)
            m.beginGesture()
            m.moveSelection(by: s(-1), duplicate: true)
            m.endKeyMove()
            #expect(x(m).track.keys.map(\.time) == [s(1), s(2), s(6), s(8)] && y(m).track.keys.count == 4)
            #expect(x(m).value(atLocal: s(2)) == 0.8 && x(m).value(atLocal: s(3)) == 0.2)
            #expect(y(m).value(atLocal: s(2)) == 10 && y(m).value(atLocal: s(3)) == (flatY ? 10 : 30))
        }
    }
}

/// The Path row's key times; a Hold Ahead is one key and one stop.
@MainActor @Suite struct MaskPathKeyTimesTests {
    final class Seeks { var times: [Time] = [] }

    @Test func timesAreClipLocalAndSorted() {
        let (m, id, _) = MaskPathKeyLaneTests().pathRig()
        #expect(m.maskPathKeyTimes(id) == [s(1), s(3)])
        #expect(m.maskPathKeyTimes(UUID()).isEmpty)
    }

    @Test func aHoldAheadIsOneKey() throws {
        let (m, id, _) = MaskPathKeyLaneTests().pathRig()
        var c = try #require(m.clip)
        let keys = try #require(c.mask(id)?.path.track.keys)
        try #require(keys.count == 2)
        var leader = keys[0]
        leader.interpolation = .holdAhead
        c.updateMask(id) { $0.path.track = KeyframeTrack(keys: [leader, keys[1]]) }
        let seeks = Seeks()
        m.onSeek = { seeks.times.append($0) }
        m.setClip(c)
        #expect(m.maskPathKeyTimes(id) == [s(1), s(3)])
        // From the Hold Ahead the next stop is the next key.
        m.playhead = s(6)
        m.goToNextMaskPathKey(id)
        #expect(seeks.times == [s(8)])
        // Right after it the playhead is on no key, and the stop before it is the Hold Ahead.
        m.playhead = s(6) + step
        let after = m.maskPathKeyframeState(id)
        m.playhead = s(7)
        #expect(after == m.maskPathKeyframeState(id))
        m.playhead = s(6) + step
        m.goToPreviousMaskPathKey(id)
        #expect(seeks.times == [s(8), s(6)])
    }
}
