import Foundation
import Testing
import SQCore
import SQPlayback
@testable import SQEditorSession

@MainActor @Suite struct SkimSessionTests {
    private func make() -> (EditorSession, StubProgramEngine) {
        let fd = Time(1, 30)
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)),
                        start: .zero, mediaDuration: Time(10, 1))
        var v = Track(kind: .video)
        try! v.overwrite(clip)
        let tl = Timeline(name: "T", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [v])
        let engine = StubProgramEngine()
        return (EditorSession(project: Project(name: "P", timelines: [tl]), engine: engine), engine)
    }

    @Test func skimShowsTheFrameWithoutMovingThePlayhead() {
        let (ses, engine) = make()
        ses.seek(to: Time(2, 1))
        ses.skim(to: Time(5, 1))
        ses.skim(to: Time(6, 1))
        #expect(ses.playhead == Time(2, 1))
        #expect(ses.skimTime == Time(6, 1))
        #expect(engine.calls.suffix(3) == [.beginScrub, .scrub(Time(5, 1)), .scrub(Time(6, 1))])
    }

    @Test func endingTheSkimShowsThePlayheadFrameAgain() {
        let (ses, engine) = make()
        ses.seek(to: Time(2, 1))
        ses.skim(to: Time(5, 1))
        ses.skim(to: nil)
        #expect(ses.skimTime == nil)
        #expect(engine.calls.suffix(2) == [.endScrub, .seek(Time(2, 1))])
        #expect(engine.position == Time(2, 1))
    }

    @Test func sameFrameIsNoSecondScrub() {
        let (ses, engine) = make()
        ses.skim(to: Time(5, 1))
        let n = engine.calls.count
        ses.skim(to: Time(5, 1))
        #expect(engine.calls.count == n)
    }

    @Test func aSeekMovesThePlayheadAndTheSkimGoesOn() {
        let (ses, engine) = make()
        ses.skim(to: Time(5, 1))
        ses.seek(to: Time(7, 1))
        #expect(ses.playhead == Time(7, 1))
        #expect(ses.skimTime == Time(5, 1))
        #expect(engine.calls.suffix(2) == [.seek(Time(7, 1)), .scrub(Time(5, 1))])      // the monitor keeps the skim frame
    }

    @Test func playingEndsTheSkim() {
        let (ses, engine) = make()
        ses.skim(to: Time(5, 1))
        ses.playPause()
        #expect(ses.skimTime == nil)
        #expect(engine.calls.contains(.endScrub))
    }

    @Test func noSkimWithoutOne() {
        let (ses, engine) = make()
        let n = engine.calls.count
        ses.skim(to: nil)
        #expect(engine.calls.count == n)
    }

    // MARK: Edit point (Q / W / Cmd+K use the hover playhead while it is visible)

    private func clipEnds(_ ses: EditorSession) -> [Time] { ses.activeTimeline!.tracks[0].clips.map { $0.timeline.end } }

    @Test func editPointIsTheSkimmerWhileVisibleElseThePlayhead() {
        let (ses, _) = make()
        ses.seek(to: Time(2, 1))
        #expect(ses.editPoint == Time(2, 1))
        ses.skim(to: Time(5, 1))
        #expect(ses.editPoint == Time(5, 1))
        ses.skim(to: nil)
        #expect(ses.editPoint == Time(2, 1))
    }

    @Test func rippleTrimUsesTheHoverPosition() {
        let (ses, _) = make()
        ses.seek(to: Time(2, 1))
        ses.skim(to: Time(5, 1))
        ses.rippleTrimToPlayhead(.tail)
        #expect(clipEnds(ses) == [Time(5, 1)])
        #expect(ses.skimTime == Time(5, 1))
    }

    @Test func rippleTrimUsesThePlayheadWithoutAHover() {
        let (ses, _) = make()
        ses.seek(to: Time(2, 1))
        ses.rippleTrimToPlayhead(.tail)
        #expect(clipEnds(ses) == [Time(2, 1)])
    }

    @Test func plainTrimAndCutUseTheHoverPosition() {
        let (ses, _) = make()
        ses.seek(to: Time(2, 1))
        ses.skim(to: Time(6, 1))
        ses.addEditAtPlayhead()
        #expect(clipEnds(ses) == [Time(6, 1), Time(10, 1)])
        ses.undo()
        ses.trimToPlayhead(.tail, mode: .plain)
        #expect(clipEnds(ses) == [Time(6, 1)])
    }

    @Test func previewRateDrivesPlayAndResetsOnClose() {
        let (ses, engine) = make()
        let fast = PreviewRate(PlaybackRate(2))
        ses.setPreviewRate(fast)
        ses.playPause()
        #expect(ses.isPlaying && engine.rate == PlaybackRate(2))
        ses.setPreviewRate(PreviewRate(PlaybackRate(1, 2)))      // switches while playing
        #expect(engine.rate == PlaybackRate(1, 2))
        ses.playPause()
        #expect(!ses.isPlaying)
        ses.closeProject()
        #expect(ses.previewRate == .normal)
    }
}
