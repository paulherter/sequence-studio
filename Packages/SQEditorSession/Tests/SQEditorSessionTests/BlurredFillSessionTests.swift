import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct BlurredFillSessionTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }

    private func makeSession(width: Int, height: Int) -> (EditorSession, Clip) {
        let info = MediaInfo(duration: s(10), video: VideoTrackInfo(width: width, height: height, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                                                    nominalFrameDuration: Time(1, 30), isVariableFrameRate: false))
        let ref = MediaRef(name: "m", path: "/x/m.mov", fingerprint: MediaFingerprint(size: 1), duration: s(10), info: info)
        let c = Clip(name: "m", media: ref.id, kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: .zero)
        var v = Track(kind: .video, isTargeted: true)
        try! v.overwrite(c)
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)), tracks: [v])
        var p = Project(name: "P", timelines: [tl])
        p.add(ref)
        return (EditorSession(project: p, engine: StubProgramEngine()), c)
    }

    @Test func fitIsOneUndoStepAndRemovable() {
        let (ses, c) = makeSession(width: 1920, height: 1080)
        ses.select(clips: [c.id])
        #expect(ses.blurredFillEnabled(.fitBlurredFill))
        #expect(ses.applyBlurredFill(.fit))
        #expect(ses.activeTimeline!.tracks.count == 2)
        #expect(ses.undoName == "Fit with Blurred Fill")
        #expect(ses.blurredFillEnabled(.removeBlurredFill))
        #expect(ses.removeBlurredFill())
        #expect(ses.activeTimeline!.tracks.count == 1)
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks.count == 2)
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks.count == 1 && ses.activeTimeline!.tracks[0].clips[0].link == nil)
    }

    @Test func commandWithTheCopySelectedActsOnThePictureAndKeepsOneUndoStep() {
        let (ses, c) = makeSession(width: 1920, height: 1080)
        ses.select(clips: [c.id])
        #expect(ses.applyBlurredFill(.fit))
        let copy = ses.activeTimeline!.tracks[0].clips[0].id
        ses.select(clips: [copy])
        #expect(ses.applyBlurredFill(.card))
        #expect(ses.activeTimeline!.tracks.count == 2)
        ses.select(clips: [copy, c.id])
        #expect(ses.removeBlurredFill())
        #expect(ses.activeTimeline!.tracks.count == 1)
        #expect(ses.undo() && ses.activeTimeline!.tracks.count == 2)
    }

    @Test func fitDoesNothingWhenTheAspectMatchesButCardStillWorks() {
        let (ses, c) = makeSession(width: 1080, height: 1920)
        ses.select(clips: [c.id])
        #expect(!ses.applyBlurredFill(.fit))
        #expect(ses.activeTimeline!.tracks.count == 1)
        #expect(ses.applyBlurredFill(.card))
        #expect(ses.undoName == "Card with Blurred Background")
        #expect(ses.activeTimeline!.tracks[1].clips[0].effects.count == 2)
    }

    @Test func commandsAreInTheClipMenuAndSupported() {
        for c in [EditorCommand.fitBlurredFill, .fitCard, .removeBlurredFill] {
            #expect(EditorMenus.clip.commands.contains(c))
            #expect(EditorMenus.menuOnly.contains(c))
            #expect(CommandSupport.isSupported(c))
        }
    }
}
