import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func vclip(_ start: Int64) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: s(start))
}

@MainActor private func makeSession(_ clips: [Clip]) -> EditorSession {
    var t = Track(kind: .video)
    for c in clips { try! t.overwrite(c) }
    return EditorSession(project: Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [t])]),
                         engine: StubProgramEngine())
}

@MainActor @Suite struct BuiltInCopyPasteTests {
    @Test func copiedTransformReplacesValuesAndKeyframesOnEverySelectedClip() throws {
        var a = vclip(0)
        a.animation.scale = AnimatedProperty(Vec2(0.5, 0.5), track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: Vec2(0.5, 0.5)), Keyframe(time: s(1), value: Vec2(0.4, 0.4))]))
        var b = vclip(2), c = vclip(4)
        b.animation.scale = AnimatedProperty(Vec2(1, 1), track: KeyframeTrack(keys: []))
        c.animation.scale = AnimatedProperty(Vec2(2, 2), track: KeyframeTrack(keys: []))
        let ses = makeSession([a, b, c])
        #expect(ses.copyBuiltIn(.motion, of: a))
        #expect(ses.effectClipboard == nil)
        ses.select(clips: [b.id, c.id])
        #expect(ses.canPasteAttributes)
        #expect(ses.pasteAttributeChoices == [.motion])
        #expect(ses.pasteAttributes())
        let clips = ses.activeTimeline!.tracks[0].clips
        for id in [b.id, c.id] {
            let out = try #require(clips.first { $0.id == id })
            #expect(out.animation.scale.track.keys.map(\.time) == [s(0), s(1)])
            #expect(out.animation.scale.track.keys.map(\.value) == [Vec2(0.5, 0.5), Vec2(0.4, 0.4)])
        }
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips.first { $0.id == b.id }?.animation.scale.track.keys.isEmpty == true)
    }

    @Test func onlyTheCopiedGroupChangesAndAClipCopyEndsTheBuiltInCopy() {
        var a = vclip(0), b = vclip(2)
        a.animation.opacity = AnimatedProperty(0.3)
        b.animation.opacity = AnimatedProperty(0.9)
        let ses = makeSession([a, b])
        #expect(!ses.copyBuiltIn(.speed, of: a))
        #expect(ses.copyBuiltIn(.motion, of: a))
        ses.select(clips: [b.id])
        _ = ses.pasteAttributes()
        #expect(ses.activeTimeline!.tracks[0].clips.first { $0.id == b.id }?.animation.opacity.value == 0.9)
        ses.select(clips: [a.id])
        #expect(ses.copySelection())
        #expect(ses.builtInClipboard == nil)
    }
}
