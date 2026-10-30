import Foundation
import Testing
import SQCore
@testable import SQEditorSession

/// Selection follows playhead: the clips under the playhead on the targeted tracks are selected as the playhead moves.
@MainActor @Suite struct SelectionFollowsPlayheadTests {
    private let fd = Time(1, 24)
    private func mk(_ s: Int64, _ n: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
        Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: fd * n), start: fd * s,
             link: link, mediaDuration: fd * 500)
    }
    private func session(_ tracks: [Track]) -> EditorSession {
        EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: fd, tracks: tracks)]))
    }

    /// Text tool bug: a new Graphic on a track that is not targeted stays selected when the playhead is re-shown.
    @Test func newGraphicOnUntargetedTrackStaysSelectedAfterSeek() {
        let a = mk(0, 100)
        let s = session([Track(kind: .video, clips: [a], isTargeted: true), Track(kind: .video)])
        s.seek(to: fd * 3)
        s.select(clips: [])
        let id = s.addGraphicsClip(at: fd * 3, duration: fd * 24, neverOverwrite: true)
        #expect(id != nil && s.selection == [id!])
        s.seek(to: s.playhead)
        #expect(s.selection == [id!])
    }

    @Test func newGraphicWithNoFollowStateStaysSelectedAfterSeek() {
        let a = mk(0, 100)
        let s = session([Track(kind: .video, clips: [a], isTargeted: true), Track(kind: .video)])
        let id = s.addGraphicsClip(at: .zero, duration: fd * 24, neverOverwrite: true)
        #expect(id != nil && s.selection == [id!])
        s.seek(to: s.playhead)
        #expect(s.selection == [id!])
    }

    @Test func crossingBoundaryReplacesSelection() {
        let a = mk(0, 10), b = mk(10, 10)
        let s = session([Track(kind: .video, clips: [a, b], isTargeted: true)])
        s.seek(to: fd * 3)
        #expect(s.selection == [a.id])
        s.seek(to: fd * 12)
        #expect(s.selection == [b.id])
    }

    @Test func gapSelectsNothing() {
        let a = mk(0, 10), b = mk(20, 10)
        let s = session([Track(kind: .video, clips: [a, b], isTargeted: true)])
        s.seek(to: fd * 3)
        s.seek(to: fd * 15)
        #expect(s.selection.isEmpty)
    }

    @Test func untargetedTracksIgnored() {
        let a = mk(0, 10), b = mk(0, 10)
        let s = session([Track(kind: .video, clips: [a]), Track(kind: .video, clips: [b], isTargeted: true)])
        s.seek(to: fd * 3)
        #expect(s.selection == [b.id])
    }

    @Test func allTargetedTracksAndLinkedAudio() {
        let l = UUID()
        let v = mk(0, 10, link: l), au = mk(0, 10, kind: .audio, link: l), other = mk(0, 10)
        let s = session([Track(kind: .video, clips: [v], isTargeted: true), Track(kind: .video, clips: [other], isTargeted: true),
                         Track(kind: .audio, clips: [au])])
        s.seek(to: fd * 3)
        #expect(s.selection == [v.id, au.id, other.id])
    }

    @Test func toggleOffChangesNothing() {
        let a = mk(0, 10)
        let s = session([Track(kind: .video, clips: [a], isTargeted: true)])
        s.setSelectionFollowsPlayhead(false)
        s.seek(to: fd * 3)
        #expect(s.selection.isEmpty)
        s.setSelectionFollowsPlayhead(true)       // switching on applies at once
        #expect(s.selection == [a.id])
    }

    @Test func manualSelectionWinsWithinSameClipEscapeStaysCleared() {
        let a = mk(0, 10), b = mk(10, 10), c = mk(20, 10)
        let s = session([Track(kind: .video, clips: [a, b, c], isTargeted: true)])
        s.seek(to: fd * 3)
        s.select(clips: [c.id])                    // manual click on another clip
        s.seek(to: fd * 5)
        #expect(s.selection == [c.id])             // same clip under the playhead: manual wins
        s.seek(to: fd * 12)
        #expect(s.selection == [b.id])             // next crossing re-follows
        s.select(clips: [])                        // Escape
        s.seek(to: fd * 15)
        #expect(s.selection.isEmpty)
        s.seek(to: fd * 22)
        #expect(s.selection == [c.id])
    }

    @Test func editResetsFollowState() {
        let a = mk(0, 10)
        let s = session([Track(kind: .video, clips: [a], isTargeted: true)])
        s.seek(to: fd * 3)
        s.select(clips: [])
        s.seek(to: fd * 4)
        #expect(s.selection.isEmpty)
    }

    // MARK: When it is evaluated (playing: never, scrub and step runs: once, deferred)

    private func three() -> (EditorSession, StubProgramEngine, [Clip]) {
        let clips = [mk(0, 10), mk(10, 10), mk(20, 10), mk(30, 10)]
        let e = StubProgramEngine()
        let s = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: fd, tracks: [
            Track(kind: .video, clips: clips, isTargeted: true)])]), engine: e)
        return (s, e, clips)
    }

    @Test func selectAllClipsOnATrackSelectsThatTrackOnlyAndSkipsLocked() {
        let a = [mk(0, 10), mk(10, 10)], b = [mk(0, 10)]
        let s = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: fd, tracks: [
            Track(kind: .video, clips: a), Track(kind: .video, clips: b)])]), engine: StubProgramEngine())
        let tracks = s.activeTimeline!.tracks
        s.selectAllClips(on: tracks[0].id)
        #expect(s.selection == Set(a.map(\.id)))
        s.selectAllClips(on: tracks[1].id)
        #expect(s.selection == Set(b.map(\.id)))
    }

    @Test func playingNeverFollowsAndTheStopFollowsOnce() {
        let (s, e, c) = three()
        s.seek(to: fd * 3)
        #expect(s.selection == [c[0].id])
        var selectionChanges = 0
        s.onChange = { if $0.contains(.selection) { selectionChanges += 1 } }
        let evaluations = s.followEvaluations
        s.playPause()
        for _ in 0..<25 { e.simulatePlayback(advance: fd) }          // crosses two boundaries
        #expect(s.isPlaying)
        #expect(s.playhead == fd * 28)
        #expect(s.selection == [c[0].id])
        #expect(selectionChanges == 0)
        #expect(s.followEvaluations == evaluations)
        s.playPause()
        #expect(!s.isPlaying)
        #expect(s.selection == [c[2].id])
        #expect(selectionChanges == 1)
        #expect(s.followEvaluations == evaluations + 1)
    }

    @Test func playbackRunningIntoTheEndFollowsOnce() {
        let (s, e, c) = three()
        s.seek(to: fd * 3)
        var selectionChanges = 0
        s.onChange = { if $0.contains(.selection) { selectionChanges += 1 } }
        let evaluations = s.followEvaluations
        s.playPause()
        for _ in 0..<60 where s.isPlaying { e.simulatePlayback(advance: fd) }
        #expect(!s.isPlaying)
        #expect(selectionChanges == 1)
        #expect(s.followEvaluations == evaluations + 1)
        #expect(s.selection == (s.playhead < fd * 40 ? [c[3].id] : []))
    }

    @Test func aManualSelectionWhilePlayingSurvivesAStopInsideTheSameClip() {
        let (s, e, c) = three()
        s.seek(to: fd * 3)
        s.playPause()
        e.simulatePlayback(advance: fd * 2)
        s.select(clips: [c[3].id])
        s.playPause()
        #expect(s.selection == [c[3].id])
    }

    /// Cmd+A (or a new title that selects itself) after playback crossed a boundary: the stop keeps it.
    @Test func aManualSelectionAfterACrossedBoundarySurvivesTheStop() {
        let (s, e, c) = three()
        s.seek(to: fd * 3)
        s.playPause()
        e.simulatePlayback(advance: fd * 12)                          // now inside the second clip
        s.selectAllClips()
        s.playPause()
        #expect(s.selection == Set(c.map(\.id)))
        // The next boundary replaces it again.
        s.seek(to: fd * 25)
        #expect(s.selection == [c[2].id])
    }

    /// A command during playback acts on the clip under the playhead: the flush before it evaluates once.
    @Test func aFlushWhilePlayingBringsTheSelectionToThePlayhead() {
        let (s, e, c) = three()
        s.seek(to: fd * 3)
        s.playPause()
        e.simulatePlayback(advance: fd * 12)
        #expect(s.selection == [c[0].id])
        let evaluations = s.followEvaluations
        s.flushFollowSelection()
        #expect(s.selection == [c[1].id])
        s.flushFollowSelection()                                      // inside the same clip: a range compare
        #expect(s.followEvaluations == evaluations + 1)
        s.playPause()
        #expect(s.selection == [c[1].id])
        #expect(s.followEvaluations == evaluations + 1)
    }

    /// Another project: a deferred evaluation of the old one is dropped.
    @Test func replacingTheProjectDropsAPendingEvaluation() async throws {
        let (s, _, _) = three()
        s.seek(to: fd * 3)
        s.beginScrub()
        s.scrub(to: fd * 15)
        #expect(s.isFollowPending)
        s.newProject(Project(name: "Q", timelines: [Timeline(name: "T", frameDuration: fd, tracks: [
            Track(kind: .video, clips: [mk(0, 10)], isTargeted: true)])]))
        #expect(!s.isFollowPending)
        #expect(s.selection.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(s.selection.isEmpty)
    }

    @Test func aScrubBurstIsOneEvaluationWhenTheDragEnds() {
        let (s, _, c) = three()
        s.seek(to: fd * 3)
        var selectionChanges = 0
        s.onChange = { if $0.contains(.selection) { selectionChanges += 1 } }
        let evaluations = s.followEvaluations
        s.beginScrub()
        for i in 3...35 { s.scrub(to: fd * Int64(i)) }                // three boundaries, 33 mouse events
        #expect(s.playhead == fd * 35)                                // the playhead itself never waits
        #expect(s.selection == [c[0].id])
        #expect(s.followEvaluations == evaluations)
        #expect(s.isFollowPending)
        s.endScrub()
        #expect(s.selection == [c[3].id])
        #expect(s.followEvaluations == evaluations + 1)
        #expect(selectionChanges == 1)
        #expect(!s.isFollowPending)
    }

    @Test func aScrubThatRestsIsEvaluatedOnceWithoutTheMouseUp() async throws {
        let (s, _, c) = three()
        s.followSettle = .milliseconds(30)
        s.seek(to: fd * 3)
        let evaluations = s.followEvaluations
        s.beginScrub()
        for i in 3...25 { s.scrub(to: fd * Int64(i)) }
        #expect(s.selection == [c[0].id])
        for _ in 0..<200 where s.isFollowPending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(s.selection == [c[2].id])
        #expect(s.followEvaluations == evaluations + 1)
        for i in 25...27 { s.scrub(to: fd * Int64(i)) }               // same clip: nothing becomes due
        #expect(!s.isFollowPending)
        s.endScrub()
        #expect(s.followEvaluations == evaluations + 1)
    }

    @Test func aRunOfFrameStepsDefersAfterTheFirst() {
        let (s, _, c) = three()
        s.seek(to: fd * 8)
        let evaluations = s.followEvaluations
        s.stepFrames(5)                                               // a single step: at once
        #expect(s.selection == [c[1].id])
        #expect(s.followEvaluations == evaluations + 1)
        for _ in 0..<4 { s.stepFrames(5) }                            // held key: 13 -> 33, two boundaries
        #expect(s.playhead == fd * 33)
        #expect(s.selection == [c[1].id])
        #expect(s.followEvaluations == evaluations + 1)
        s.flushFollowSelection()                                      // what any command does first
        #expect(s.selection == [c[3].id])
        #expect(s.followEvaluations == evaluations + 2)
    }

    @Test func aClickWhileAnEvaluationIsDueWins() {
        let (s, _, c) = three()
        s.seek(to: fd * 3)
        s.beginScrub()
        s.scrub(to: fd * 15)
        s.select(clips: [c[3].id])
        #expect(!s.isFollowPending)
        s.endScrub()
        #expect(s.selection == [c[3].id])
        s.seek(to: fd * 16)                                           // same clip under the playhead: the click holds
        #expect(s.selection == [c[3].id])
        s.seek(to: fd * 22)
        #expect(s.selection == [c[2].id])
    }

    @Test func followingIsNoUndoStepAndLeavesTheProjectClean() {
        let (s, e, _) = three()
        let project = s.project
        s.seek(to: fd * 3); s.seek(to: fd * 12)
        s.beginScrub(); s.scrub(to: fd * 25); s.endScrub()
        s.playPause(); e.simulatePlayback(advance: fd * 8); s.playPause()
        #expect(!s.selection.isEmpty)
        #expect(!s.canUndo)
        #expect(!s.isDirty)
        #expect(s.history.undoDepth == 0)
        #expect(s.project == project)
    }
}
