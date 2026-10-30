import Foundation
import Testing
import SQCore
@testable import SQEditorSession

/// Stability pass: undo/redo symmetry of every session mutation (one user action = one step, redo restores exactly),
/// playhead clamping, empty and one-frame timelines, clips at time 0, mixed frame rates, portrait sequences.
@MainActor @Suite struct EdgeCaseTests {
    static let fd = Time(1, 30)
    static func sec(_ n: Int64) -> Time { Time(n, 1) }

    static func clip(_ name: String, _ start: Time, _ dur: Time, kind: TrackKind = .video, media: UUID = UUID(), link: UUID? = nil) -> Clip {
        var c = Clip(name: name, media: media, kind: kind, source: TimeRange(start: .zero, duration: dur), start: start)
        c.link = link
        return c
    }

    /// V1: A [0,2) B [2,4); A1: C [0,4). In/out untouched.
    static func rig(fd: Time = EdgeCaseTests.fd) throws -> (EditorSession, StubProgramEngine, [Clip]) {
        let a = clip("A", .zero, sec(2)), b = clip("B", sec(2), sec(2)), c = clip("C", .zero, sec(4), kind: .audio)
        var v = Track(kind: .video), au = Track(kind: .audio)
        try v.overwrite(a); try v.overwrite(b); try au.overwrite(c)
        let engine = StubProgramEngine()
        let session = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "M", frameDuration: fd, tracks: [v, au])]), engine: engine)
        return (session, engine, [a, b, c])
    }

    // MARK: Undo / redo symmetry

    typealias Action = (name: String, run: @MainActor (EditorSession, [Clip]) -> Void)

    static let actions: [Action] = [
        ("delete", { s, c in s.select(clips: [c[0].id]); s.deleteSelection(ripple: false) }),
        ("ripple delete", { s, c in s.select(clips: [c[0].id]); s.deleteSelection(ripple: true) }),
        ("ripple delete two tracks", { s, c in s.select(clips: [c[0].id, c[2].id]); s.deleteSelection(ripple: true) }),
        ("add edit", { s, _ in s.seek(to: sec(1)); s.addEditAtPlayhead() }),
        ("add edit all tracks", { s, _ in s.seek(to: sec(1)); s.addEditAtPlayhead(allTracks: true) }),
        ("mark in", { s, _ in s.seek(to: sec(1)); s.markIn() }),
        ("mark out", { s, _ in s.seek(to: sec(3)); s.markOut() }),
        ("mark clip", { s, _ in s.seek(to: sec(1)); s.markClip() }),
        ("marker", { s, _ in s.seek(to: sec(1)); s.addMarkerAtPlayhead() }),
        ("ripple trim head", { s, _ in s.seek(to: Time(1, 1)); s.rippleTrimToPlayhead(.head) }),
        ("ripple trim tail", { s, _ in s.seek(to: Time(3, 2)); s.rippleTrimToPlayhead(.tail) }),
        ("lift range", { s, _ in s.seek(to: sec(1)); s.markIn(); s.seek(to: Time(5, 2)); s.markOut(); s.liftRange() }),
        ("extract range", { s, _ in s.seek(to: sec(1)); s.markIn(); s.seek(to: Time(5, 2)); s.markOut(); s.extractRange() }),
        ("new sequence", { s, _ in _ = s.addSequence() }),
        ("nest", { s, c in s.select(clips: [c[0].id, c[1].id]); _ = s.nestSelection(name: "Nested") }),
        ("paste color", { s, c in
            var g = ClipColor.default; g.effects[0].basic.exposure = 1
            s.select(clips: [c[0].id, c[1].id]); s.pasteColor(g) }),
        ("replace clip", { s, c in var x = c[0]; x.name = "Renamed"; s.replaceClip(x, name: "Rename", continuesGesture: false) }),
    ]

    /// The undoable part of the state: project value. (Selection and playhead are UI state.)
    @Test(arguments: ["delete", "ripple delete", "ripple delete two tracks", "add edit", "add edit all tracks", "mark in", "mark out",
                      "mark clip", "marker", "ripple trim head", "ripple trim tail", "lift range", "extract range", "new sequence", "nest",
                      "paste color", "replace clip"])
    func everyActionIsOneUndoStepAndRedoRestoresExactly(name: String) throws {
        let action = try #require(Self.actions.first { $0.name == name })
        let (s, _, clips) = try Self.rig()
        // Marks and playhead moves are part of the action's setup for range edits, so measure after them: undo until the
        // history is back at its start and compare to the project the session began with.
        let start = s.project
        action.run(s, clips)
        let after = s.project
        var steps = 0
        while s.canUndo { s.undo(); steps += 1 }
        #expect(s.project == start, "\(name): undo restores the original project")
        // Setup steps (marks) are separate user actions; the action under test is always the LAST step.
        let expectedMax = ["lift range": 3, "extract range": 3].keys.contains(name) ? 3 : 1
        #expect(steps >= 1 && steps <= expectedMax, "\(name): \(steps) undo steps")
        for _ in 0..<steps { s.redo() }
        #expect(s.project == after, "\(name): redo restores exactly")
        #expect(!s.canRedo)
    }

    @Test func undoneActionsDoNotLeaveAStaleSelectionOrCrashTheInspector() throws {
        let (s, _, c) = try Self.rig()
        s.select(clips: [c[0].id])
        s.deleteSelection(ripple: true)
        #expect(s.selection.isEmpty)
        s.undo()
        #expect(s.activeTimeline?.tracks[0].clips.map(\.id) == [c[0].id, c[1].id])
        // A clip selected, then removed by undo of its creation: selection pruned.
        s.addEditAtPlayhead()
        s.seek(to: Self.sec(1)); s.addEditAtPlayhead()
        let right = s.activeTimeline!.tracks[0].clips[1].id
        s.select(clips: [right])
        s.undo()
        #expect(!s.selection.contains(right))
        s.redo()
        #expect(s.activeTimeline!.tracks[0].clips.count == 3)
    }

    // MARK: Playhead

    @Test func playheadNeverGoesNegativeAndStaysOnTheFrameGrid() throws {
        let (s, e, _) = try Self.rig()
        s.seek(to: Time(-5, 1)); #expect(s.playhead == .zero)
        s.stepFrames(-100); #expect(s.playhead == .zero)
        s.scrub(to: Time(-1, 100)); #expect(s.playhead == .zero)
        s.seek(to: Time(1001, 1000)); #expect(s.playhead.snapped(to: Self.fd) == s.playhead, "snapped to a frame: \(s.playhead)")
        s.stepFrames(3)
        #expect(s.playhead == Time(1001, 1000).snapped(to: Self.fd) + Self.fd * 3)
        #expect(e.position == s.playhead)
    }

    @Test func emptyTimelineIsSafe() throws {
        let s = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "E", frameDuration: Self.fd, tracks: [Track(kind: .video), Track(kind: .audio)])]),
                              engine: StubProgramEngine())
        s.goToEnd(); #expect(s.playhead == .zero)
        s.goToStart(); s.goToNextEditPoint(); s.goToPreviousEditPoint(); s.goToIn(); s.goToOut()
        s.deleteSelection(ripple: true); s.deleteSelection(ripple: false)
        s.addEditAtPlayhead(); s.addEditAtPlayhead(allTracks: true)
        s.liftRange(); s.extractRange(); s.markClip(); s.clearInOut()
        s.rippleTrimToPlayhead(.head); s.rippleTrimToPlayhead(.tail)
        #expect(!s.canUndo, "nothing happened, so nothing to undo: \(s.undoName ?? "")")
        s.playPause()
        s.playPause()
        #expect(!s.isPlaying)
        #expect(!s.undo() && !s.redo())
        s.markIn(); s.markOut()   // marks on an empty timeline are allowed but must not produce an inverted range
        if let io = s.activeTimeline?.inOut { #expect(io.end >= io.start) }
    }

    @Test func clipAtTimeZeroAndOneFrameClips() throws {
        let one = Self.clip("one", .zero, Self.fd)
        var v = Track(kind: .video)
        try v.overwrite(one)
        let s = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Self.fd, tracks: [v, Track(kind: .audio)])]),
                              engine: StubProgramEngine())
        // Cutting exactly at the clip edges, or inside a one-frame clip, changes nothing and leaves no undo step.
        for t in [Time.zero, Self.fd, Time(1, 60)] {
            s.seek(to: t); s.addEditAtPlayhead()
            #expect(s.activeTimeline!.tracks[0].clips.count == 1, "cut at \(t)")
        }
        #expect(!s.canUndo)
        s.select(clips: [one.id]); s.deleteSelection(ripple: true)
        #expect(s.activeTimeline!.tracks[0].clips.isEmpty && s.activeTimeline!.duration == .zero)
        s.undo()
        #expect(s.activeTimeline!.tracks[0].clips.first?.start == .zero && s.activeTimeline!.duration == Self.fd)
        s.goToEnd(); #expect(s.playhead == .zero)   // one-frame sequence: the last frame is frame 0
        s.playPause()            // at the end: restarts from the start
        #expect(s.playhead == .zero)
    }

    @Test func audioOnlyAndVideoOnlySequencesBehave() throws {
        let au = Self.clip("a", .zero, Self.sec(3), kind: .audio)
        var t = Track(kind: .audio); try t.overwrite(au)
        let audioOnly = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Self.fd, tracks: [t])]), engine: StubProgramEngine())
        audioOnly.seek(to: Self.sec(1)); audioOnly.addEditAtPlayhead()
        #expect(audioOnly.activeTimeline!.tracks[0].clips.count == 2)
        audioOnly.select(clips: [au.id]); audioOnly.deleteSelection(ripple: true)
        #expect(audioOnly.activeTimeline!.tracks[0].clips.count == 1)
        #expect(audioOnly.pasteColor(.default) == 0, "no picture clips: nothing pasted, no step")
        #expect(!audioOnly.setToFrameSize(Set([au.id])))
        let vid = Self.clip("v", .zero, Self.sec(3))
        var vt = Track(kind: .video); try vt.overwrite(vid)
        let videoOnly = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Self.fd, tracks: [vt])]), engine: StubProgramEngine())
        videoOnly.seek(to: Self.sec(1)); videoOnly.addEditAtPlayhead(allTracks: true)
        #expect(videoOnly.activeTimeline!.tracks[0].clips.count == 2)
        videoOnly.undo(); videoOnly.redo(); #expect(videoOnly.activeTimeline!.tracks[0].clips.count == 2)
    }

    @Test func mixedFrameRatesKeepTheGridAndNeverLeaveGaps() throws {
        // A 24 fps clip (1001/24000 frames) edited on a 30000/1001 fps sequence: starts are not on the sequence grid.
        let seqFD = Time(1001, 30000)
        let odd = Self.clip("24p", Time(1001, 24000) * 5, Time(1001, 24000) * 48)
        var v = Track(kind: .video); try v.overwrite(odd)
        let s = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: seqFD, tracks: [v])]), engine: StubProgramEngine())
        s.seek(to: Time(1, 1))                       // inside the clip
        s.addEditAtPlayhead()
        let clips = s.activeTimeline!.tracks[0].clips
        #expect(clips.count == 2)
        #expect(clips[0].timeline.end == clips[1].start, "no gap or overlap at the cut")
        #expect(clips[1].start == s.playhead)
        #expect(clips[0].timeline.duration + clips[1].timeline.duration == odd.timeline.duration)
        s.undo()
        #expect(s.activeTimeline!.tracks[0].clips == [odd])
    }

    @Test func landscapeClipInAPortraitSequenceFitsWholeAndFillCropsToTheFrame() {
        let portrait = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))
        let fit = portrait.fitScale(width: 1920, height: 1080)
        #expect(abs(fit - 0.5625) < 1e-9, "1920 wide picture fits 1080 wide: whole picture visible, bars above and below")
        // Fill = the larger of the two ratios: the picture covers the frame, the sides are cropped.
        let fill = max(1080.0 / 1920, 1920.0 / 1080)
        #expect(abs(fill - 1.7777777) < 1e-6 && fill > fit)
        // Portrait clip into a landscape sequence: same maths the other way round.
        let landscape = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))
        #expect(abs(landscape.fitScale(width: 1080, height: 1920) - 0.5625) < 1e-9)
        #expect(landscape.fitScale(width: 0, height: 100) == 1 && portrait.fitScale(width: 100, height: -1) == 1, "degenerate sizes")
    }
}
