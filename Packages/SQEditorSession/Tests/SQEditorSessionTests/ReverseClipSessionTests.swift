import Foundation
import SQCore
import SQUIKit
import Testing
@testable import SQEditorSession

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

@MainActor
@Suite struct ReverseClipSessionTests {
    private func make(linkedAudio: Bool = false) -> (EditorSession, Clip) {
        let link: UUID? = linkedAudio ? UUID() : nil
        let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: f(300), duration: f(150)), start: .zero,
                     link: link, mediaDuration: f(4000))
        var t = Track(kind: .video)
        try! t.overwrite(c)
        var tracks = [t]
        if let link {
            let a = Clip(name: "a", media: c.media, kind: .audio, source: c.source, start: .zero, link: link, mediaDuration: f(4000))
            var at = Track(kind: .audio)
            try! at.overwrite(a)
            tracks.append(at)
        }
        return (EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: fd, tracks: tracks)])), c)
    }
    private func all(_ s: EditorSession) -> [Clip] { s.activeTimeline!.tracks.flatMap(\.clips) }

    @Test func constantSpeedTogglesTwiceToIdentityInOneStepEach() {
        let (ses, c) = make()
        ses.select(clips: [c.id], captions: [])
        let before = all(ses)
        let depth = ses.undoDepth
        #expect(ses.canReverseSelection)
        #expect(ses.toggleReverseSelection())
        #expect(ses.undoDepth == depth + 1)
        #expect(all(ses)[0].reversed)
        #expect(ses.toggleReverseSelection())
        #expect(ses.undoDepth == depth + 2)
        #expect(all(ses) == before)
    }

    @Test func animatedSpeedReversesAndComesBack() {
        let (ses, c) = make()
        ses.select(clips: [c.id], captions: [])
        #expect(ses.applySpeedPreset(.punch, onBeat: false) == .applied(clips: 1))
        let before = all(ses)[0]
        #expect(before.speedKeys != nil)
        #expect(ses.toggleReverseSelection())
        let rev = all(ses)[0]
        #expect(rev.reversed && rev.speedKeys != nil && rev.duration == before.duration)
        #expect(ses.toggleReverseSelection())
        let back = all(ses)[0]
        #expect(!back.reversed && back.speedKeys == before.speedKeys && back.duration == before.duration)
    }

    @Test func linkedAudioFollowsAndUndoIsOneStep() {
        let (ses, _) = make(linkedAudio: true)
        // Linked selection (the default in the app) selects both halves; a held-back partner stays as it is (editing(only:)).
        ses.select(clips: Set(all(ses).map(\.id)), captions: [])
        let depth = ses.undoDepth
        #expect(ses.toggleReverseSelection())
        #expect(all(ses).map(\.reversed) == [true, true])
        #expect(ses.undoDepth == depth + 1)
        ses.undo()
        #expect(all(ses).map(\.reversed) == [false, false])
    }

    @Test func notAvailableWithoutSelection() {
        let (ses, _) = make()
        #expect(!ses.canReverseSelection)
        #expect(!ses.toggleReverseSelection())
    }

    @Test func shortcutResolvesWithoutConflict() {
        for m in [CommandMap.sqDefault, CommandMap.premiereDefault] {
            #expect(m.duplicates.isEmpty)
            #expect(m.command(for: KeyBinding(.char("r"), [.control, .option]), focus: .timeline) == .reverseClip)
        }
        #expect(!EditorMenus.menuOnly.contains(.reverseClip))
    }
}
