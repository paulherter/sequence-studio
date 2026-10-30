import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct LineKeyNudgeTests {
    private let frame = Time(1, 30)

    private func makeSession() -> (EditorSession, Clip.ID, [UUID]) {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero,
                     mediaDuration: Time(60, 1))
        let a = c.addOpacityKey(atLocal: Time(2, 1))!, b = c.addOpacityKey(atLocal: Time(4, 1))!
        var v = Track(kind: .video, isTargeted: true)
        try! v.overwrite(c)
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v])
        return (EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine()), c.id, [a, b])
    }

    private func times(_ s: EditorSession, _ id: Clip.ID) -> [Time] {
        s.activeTimeline!.tracks[0].clips.first { $0.id == id }!.animation.opacity.track.keys.map(\.time)
    }

    @Test func nudgeMovesSelectedKeysNotTheClip() {
        let (s, id, keys) = makeSession()
        s.select(clips: [id])
        s.selectLineKeys([LineKeyRef(clip: id, property: .opacity, key: keys[0])])
        s.nudgeSelection(frames: 1)
        #expect(times(s, id) == [Time(2, 1) + frame, Time(4, 1)])
        #expect(s.activeTimeline!.tracks[0].clips[0].start == .zero)
        #expect(s.undoName == "Nudge Keyframes")
        s.nudgeSelection(frames: -10)
        #expect(times(s, id) == [Time(2, 1) - frame * 9, Time(4, 1)])
        s.nudgeSelection(frames: -100_000)
        #expect(times(s, id) == [Time(0, 1), Time(4, 1)])     // clamped at the clip start
    }

    @Test func clampsAtClipEnd() {
        let (s, id, keys) = makeSession()
        s.select(clips: [id])
        s.selectLineKeys([LineKeyRef(clip: id, property: .opacity, key: keys[1])])
        s.nudgeSelection(frames: 100_000)
        #expect(times(s, id).last == Time(10, 1))
    }

    @Test func changingTheClipSelectionDropsKeySelection() {
        let (s, id, keys) = makeSession()
        s.select(clips: [id])
        s.selectLineKeys([LineKeyRef(clip: id, property: .opacity, key: keys[0])])
        s.select(clips: [])
        #expect(s.selectedLineKeys.isEmpty)
        s.select(clips: [id])
        s.nudgeSelection(frames: 1)
        #expect(s.activeTimeline!.tracks[0].clips[0].start == frame)   // back to moving the clip
    }

    @Test func keysOfAnUnselectedClipAreIgnored() {
        let (s, id, keys) = makeSession()
        s.selectLineKeys([LineKeyRef(clip: id, property: .opacity, key: keys[0])])
        #expect(s.selectedLineKeys.isEmpty)      // keys follow the clip selection: none selected, none kept
    }

    @Test func volumeKeysKeepTheirLevel() {
        let (s, id, _) = makeSession()
        var k = UUID()
        s.attempt("setup") { t in
            var c = t.tracks[0].clips[0]
            k = c.addVolumeKey(atLocal: Time(3, 1))
            c.moveVolumeKey(k, toLocal: Time(3, 1), gainDB: -6)
            try t.replaceClip(c)
        }
        s.select(clips: [id])
        s.selectLineKeys([LineKeyRef(clip: id, property: .volume, key: k)])
        s.nudgeSelection(frames: 3)
        let moved = s.activeTimeline!.tracks[0].clips[0].animation.volume.track.key(id: k)!
        #expect(moved.time == Time(3, 1) + frame * 3)
        #expect(abs(AudioGain.db(fromLinear: moved.value) + 6) < 0.01)
    }
}
