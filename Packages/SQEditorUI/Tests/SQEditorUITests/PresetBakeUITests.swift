import Foundation
import Testing
import SQCore
import SQLibrary
@testable import SQEditorSession
@testable import SQEditorUI
@testable import SQInspectorUI

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}
private func track(_ clips: [Clip]) -> Track {
    var t = Track(kind: .video)
    for c in clips { try! t.overwrite(c) }
    return t
}
@MainActor private func makeSession(_ tracks: [Track]) -> EditorSession {
    EditorSession(project: Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: fd, tracks: tracks)]),
                  engine: StubProgramEngine())
}
private func withTransform(_ c: Clip) -> (Clip, ClipEffect.ID) {
    var c = c
    let e = ClipEffect(kind: ClipEffect.transformKind)
    c.effects.append(e)
    return (c, e.id)
}

/// W7.5 bake UI + motion effect list.
@MainActor @Suite struct PresetBakeUITests {
    @Test func convertAndReopenAreOneUndoStepEach() {
        let (c, eid) = withTransform(clip(0, 4))
        let ses = makeSession([track([c])])
        #expect(ses.canConvertToKeyframes(effect: eid, in: c.id))
        #expect(!ses.canReopenAsEffect(in: c.id))
        #expect(ses.convertToKeyframes(effect: eid, in: c.id))
        #expect(ses.bakeClip(c.id)?.effects.isEmpty == true)
        #expect(ses.canReopenAsEffect(in: c.id))
        #expect(ses.reopenAsEffect(in: c.id))
        #expect(ses.bakeClip(c.id)?.effects.count == 1)
        #expect(ses.undo())
        #expect(ses.bakeClip(c.id)?.effects.isEmpty == true)
        #expect(ses.undo())
        #expect(ses.bakeClip(c.id)?.effects.count == 1)
    }

    @Test func refusalsSetTheStatusError() {
        let (c, _) = withTransform(clip(0, 4))
        let ses = makeSession([track([c])])
        #expect(!ses.reopenAsEffect(in: c.id))
        #expect(ses.lastError == "There is nothing to re-open.")
        ses.clearError()
        #expect(!ses.convertToKeyframes(effect: UUID(), in: c.id))
        #expect(ses.lastError?.contains("cannot be converted") == true)
    }

    @Test func modelEnablesFromClipAndHooks() {
        let (c, eid) = withTransform(clip(0, 4))
        let m = EffectControlsModel()
        m.setClip(c)
        let sec = EffectSection.effect(eid, kind: ClipEffect.transformKind)
        #expect(m.canConvertToKeyframes(sec))
        #expect(!m.canConvertToKeyframes(.motion))
        #expect(!m.canReopenAsEffect)
        var got: (Clip.ID, ClipEffect.ID)?
        m.onConvertToKeyframes = { got = ($0, $1) }
        m.convertToKeyframes(sec)
        #expect(got?.0 == c.id && got?.1 == eid)
        m.canConvert = { _, _ in false }
        #expect(!m.canConvertToKeyframes(sec))
    }

    @Test func relativeApplyDiffersFromAbsolute() throws {
        var src = clip(0, 4)
        src.animation.position = AnimatedProperty(Vec2(100, 0))
        let preset = EffectPreset.capture(from: src, anchor: .start)
        var target = clip(4, 4)
        target.animation.position = AnimatedProperty(Vec2(10, 5))
        let item = try EditorSession.effectPresetItem(name: "P", preset: preset)
        let a = makeSession([track([target])]), r = makeSession([track([target])])
        a.select(clips: [target.id]); r.select(clips: [target.id])
        #expect(a.applyPreset(item, mode: .absolute))
        #expect(r.applyPreset(item, mode: .relative))
        #expect(a.bakeClip(target.id)?.animation.position.value == Vec2(100, 0))
        #expect(r.bakeClip(target.id)?.animation.position.value == Vec2(110, 5))
    }

    @Test func applyModeSettingRoundTrips() {
        let d = UserDefaults(suiteName: "sq.test.\(UUID().uuidString)")!
        #expect(PresetApplyModeSetting.load(from: d) == .absolute)
        PresetApplyModeSetting.save(.relative, to: d)
        #expect(PresetApplyModeSetting.load(from: d) == .relative)
    }

    @Test func motionKindsAreListed() {
        let ids = Set(EffectsPanelView.catalog.map(\.id))
        // FB-G: Move / Zoom / Pop / Fade are transitions now (Fade = a one-sided Cross Dissolve).
        for k in ClipEffect.motionKinds { #expect(ids.contains(k) == !MotionEffects.retiredKinds.contains(k)) }
        for k in TransitionKind.elementKinds { #expect(ids.contains(EffectsPanelView.transitionID(k))) }
        let loops = EffectsPanelView.catalog.filter { $0.category == "Motion" }.map(\.id)
        #expect(Set(loops) == [ClipEffect.shakeKind, ClipEffect.bounceKind, ClipEffect.pulseKind, ClipEffect.wiggleKind])
    }
}
