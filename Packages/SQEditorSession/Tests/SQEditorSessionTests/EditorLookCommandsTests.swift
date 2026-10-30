import Foundation
import Testing
import SQCore
import SQUIKit
@testable import SQEditorSession

/// The clip look commands (fades, frame holds, Dynamic Zoom, blurred fill, split screen, punch-in, subject mask) run
/// from the session alone, so the shell on the Mac and on Windows and the AppKit app share one implementation.
@MainActor @Suite struct EditorLookCommandsTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }

    private func makeSession(width: Int = 1920, height: Int = 1080) -> (EditorSession, Clip) {
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

    @Test func everyLookCommandIsOwnedHere() {
        let owned: [EditorCommand] = [.videoFadeIn, .videoFadeOut, .addFrameHold, .insertFrameHold, .dynamicZoomIn, .dynamicZoomOut,
                                      .fitBlurredFill, .fitCard, .removeBlurredFill, .togglePunchIn, .addSubjectMask,
                                      .splitScreen(.sideBySide, animated: false)]
        for c in owned { let ok = EditorLookCommands.handles(c); #expect(ok, "\(c)") }
        #expect(!EditorLookCommands.handles(.autoReframe))
        #expect(!EditorLookCommands.handles(.stabilize))
    }

    @Test func fadeInRunsAndUndoes() {
        let (ses, c) = makeSession()
        ses.select(clips: [c.id])
        #expect(EditorLookCommands.enabled(.videoFadeIn, session: ses) == true)
        #expect(EditorLookCommands.run(.videoFadeIn, session: ses) == "")
        #expect(ses.undoName == "Fade In")
    }

    @Test func fadeWithoutAClipSaysWhy() {
        let (ses, _) = makeSession()
        ses.seek(to: s(9))
        #expect(EditorLookCommands.run(.videoFadeOut, session: ses) == "Select a video clip to fade out.")
    }

    @Test func frameHoldNeedsThePlayheadOnAClip() {
        let (ses, c) = makeSession()
        ses.select(clips: [c.id])
        ses.seek(to: s(2))
        #expect(EditorLookCommands.enabled(.addFrameHold, session: ses) == true)
        #expect(EditorLookCommands.run(.addFrameHold, session: ses) == "")
        ses.seek(to: s(9))
        #expect(EditorLookCommands.enabled(.insertFrameHold, session: ses) == false)
    }

    @Test func dynamicZoomTellsWhereTheKeysAre() {
        let (ses, c) = makeSession()
        ses.select(clips: [c.id])
        let line = EditorLookCommands.run(.dynamicZoomIn, session: ses)
        #expect(line?.hasPrefix("Dynamic Zoom: Scale and Position keys") == true)
        ses.select(clips: [])
        ses.seek(to: s(9))     // no selection and the playhead off the clip: nothing to zoom
        #expect(EditorLookCommands.run(.dynamicZoomOut, session: ses) == "Select a video clip to zoom.")
    }

    @Test func blurredFillFollowsTheMenuRules() {
        let (ses, c) = makeSession()
        ses.select(clips: [c.id])
        #expect(EditorLookCommands.enabled(.fitBlurredFill, session: ses) == true)
        #expect(EditorLookCommands.enabled(.removeBlurredFill, session: ses) == false)
        #expect(EditorLookCommands.run(.fitBlurredFill, session: ses) == "")
        #expect(ses.activeTimeline!.tracks.count == 2)
        #expect(EditorLookCommands.enabled(.removeBlurredFill, session: ses) == true)
        #expect(EditorLookCommands.run(.removeBlurredFill, session: ses) == "")
    }

    @Test func aRefusedLookFlashesInsteadOfStayingSilent() {
        let (ses, _) = makeSession()
        ses.seek(to: s(9))
        #expect(EditorLookCommands.run(.fitCard, session: ses) == "Select a video clip to put on a card.")
        #expect(EditorLookCommands.run(.togglePunchIn, session: ses) == "Select a video clip to punch in.")
        #expect(EditorLookCommands.run(.addSubjectMask, session: ses) == "Select a video clip without a subject mask.")
    }

    @Test func notALookCommandReturnsNil() {
        let (ses, _) = makeSession()
        #expect(EditorLookCommands.run(.playPause, session: ses) == nil)
        #expect(EditorLookCommands.enabled(.playPause, session: ses) == nil)
    }
}
