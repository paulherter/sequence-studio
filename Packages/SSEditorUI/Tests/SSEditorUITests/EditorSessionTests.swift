import CoreMedia
import Foundation
import Testing
import SSCore
import SSMedia
@testable import SSEditorUI

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }

private func clip(_ start: Int64, _ dur: Int64, media: UUID = UUID()) -> Clip {
    Clip(name: "c\(start)", media: media, kind: .video,
         source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}

/// Timeline V1 with clips [0,2) and [2,4) and an empty A1.
@MainActor private func makeProject() throws -> (Project, Timeline, Clip, Clip) {
    let a = clip(0, 2), b = clip(2, 2)
    var v = Track(kind: .video)
    try v.overwrite(a); try v.overwrite(b)
    let t = Timeline(name: "Main", frameDuration: fd, tracks: [v, Track(kind: .audio)])
    return (Project(name: "P", timelines: [t]), t, a, b)
}

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("ss-session-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// Mutable clock for the autosave tests.
private final class SessionTestClock: @unchecked Sendable {
    var now: Date
    init(_ d: Date) { now = d }
}

@MainActor private struct Rig {
    let session: EditorSession
    let engine: StubProgramEngine
    let clock: SessionTestClock
    let dir: URL
    let store: AutosaveStore
    let t: Timeline
    let a: Clip, b: Clip

    init(policy: AutosavePolicy = AutosavePolicy(interval: 300, keep: 10)) throws {
        let (p, t, a, b) = try makeProject()
        engine = StubProgramEngine()
        clock = SessionTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        dir = tempDir()
        store = AutosaveStore(base: dir.appendingPathComponent("Autosave"), policy: policy)
        let c = clock
        session = EditorSession(project: p, engine: engine, autosaveStore: store, clock: { c.now })
        self.t = t; self.a = a; self.b = b
    }

    var timeline: Timeline { session.activeTimeline! }
}

@MainActor @Suite struct EditorSessionTests {
    // MARK: Engine and undo

    @Test func startPushesActiveTimelineToEngine() throws {
        let r = try Rig()
        #expect(r.engine.timeline == r.t)
        #expect(r.session.activeTimelineID == r.t.id)
    }

    @Test func performPushesSetTimelineAfterCommit() throws {
        let r = try Rig()
        let before = r.engine.timelines.count
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        #expect(r.engine.timelines.count == before + 1)
        #expect(r.engine.timeline == r.timeline)
        #expect(r.engine.timeline?.tracks[0].clips.count == 1)
    }

    @Test func undoAndRedoUpdateEngineTimeline() throws {
        let r = try Rig()
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        let edited = r.timeline
        #expect(r.session.undoName == "Delete")
        r.session.undo()
        #expect(r.engine.timeline == r.t)
        #expect(r.session.canRedo)
        r.session.redo()
        #expect(r.engine.timeline == edited)
    }

    @Test func projectOnlyEditDoesNotPushTimeline() throws {
        let r = try Rig()
        let n = r.engine.timelines.count
        r.session.perform("Rename") { $0.name = "Other" }
        #expect(r.engine.timelines.count == n)
        #expect(r.session.project.name == "Other")
    }

    @Test func failedEditLeavesHistoryAndEngineUntouched() throws {
        let r = try Rig()
        let n = r.engine.timelines.count
        #expect(throws: EditError.clipNotFound) {
            try r.session.performTimeline("Bad") { try $0.lift([UUID()]) }
        }
        #expect(!r.session.isDirty)
        #expect(!r.session.canUndo)
        #expect(r.engine.timelines.count == n)
    }

    @Test func coalescedEditsMakeOneUndoStep() throws {
        let r = try Rig()
        try r.session.performTimeline("Move", coalescing: "drag") { try $0.move(r.a.id, to: s(10)) }
        try r.session.performTimeline("Move", coalescing: "drag") { try $0.move(r.a.id, to: s(12)) }
        r.session.undo()
        #expect(r.timeline == r.t)
        #expect(!r.session.canUndo)
    }

    @Test func nestingCycleIsRefusedByPerformTimeline() throws {
        let r = try Rig()
        // A clip that nests the sequence into itself must be refused and leave no undo step.
        let cyc = Clip(name: "self", media: r.t.id, kind: .video, source: TimeRange(start: .zero, duration: s(1)),
                       start: s(20), sequence: r.t.id)
        #expect(throws: EditError.nestingCycle) {
            try r.session.performTimeline("Insert") { try $0.insert([(cyc, $0.tracks[0].id)], at: s(20)) }
        }
        #expect(!r.session.canUndo)
    }

    // MARK: Dirty

    @Test func dirtyFlagFollowsEditsUndoAndSave() async throws {
        let r = try Rig()
        #expect(!r.session.isDirty)
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        #expect(r.session.isDirty)
        r.session.undo()
        #expect(!r.session.isDirty)
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        try await r.session.saveAs(to: r.dir.appendingPathComponent("a.ssproj"))
        #expect(!r.session.isDirty)
        try r.session.performTimeline("Delete") { try $0.lift([r.b.id]) }
        #expect(r.session.isDirty)
    }

    @Test func editAfterSaveSnapshotStaysDirty() async throws {
        let r = try Rig()
        try await r.session.saveAs(to: r.dir.appendingPathComponent("a.ssproj"))
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        try await r.session.save()
        #expect(!r.session.isDirty)
    }

    // MARK: Selection and playhead

    @Test func selectionIsPrunedWhenClipsDisappear() throws {
        let r = try Rig()
        r.session.select(clips: [r.a.id, r.b.id])
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        #expect(r.session.selection == [r.b.id])
        r.session.undo()
        #expect(r.session.selection == [r.b.id])
    }

    @Test func seekClampsAndTellsEngine() throws {
        let r = try Rig()
        r.session.seek(to: Time(61, 30))
        #expect(r.session.playhead == Time(61, 30))
        #expect(r.engine.calls.last == .seek(Time(61, 30)))
        r.session.seek(to: s(-3))
        #expect(r.session.playhead == .zero)
    }

    @Test func enginePositionDrivesPlayheadWithoutSeekingBack() throws {
        let r = try Rig()
        r.session.playPause()
        let calls = r.engine.calls.count
        r.engine.simulatePlayback(advance: Time(3, 30))
        #expect(r.session.playhead == Time(3, 30))
        #expect(r.engine.calls.count == calls)
    }

    @Test func playbackStopsAtSequenceEndAndRestartsFromStart() throws {
        let r = try Rig()
        r.session.playPause()
        r.engine.simulatePlayback(advance: Time(119, 30))      // last presented frame, one before the 4 s end
        #expect(!r.session.isPlaying)
        #expect(r.engine.rate.isPaused)
        #expect(r.session.playhead == s(4))
        r.session.playPause()                                   // Play at the end: back to the start
        #expect(r.session.isPlaying)
        #expect(r.session.playhead == .zero)
    }

    @Test func engineStoppingItselfLeavesPlaying() throws {
        let r = try Rig()
        r.session.playPause()
        r.engine.pause()                                        // engine stopped at the edge on its own
        r.engine.onPositionChange?(.zero)
        #expect(!r.session.isPlaying)
    }

    @Test func stopPlaybackStaysStoppedEvenWhenTheEngineReportsLate() throws {
        let r = try Rig()
        r.session.playPause()
        r.engine.simulatePlayback(advance: Time(3, 30))
        r.session.stopPlayback()
        #expect(!r.session.isPlaying && r.engine.rate.isPaused)
        r.engine.simulatePlayback(advance: Time(5, 30))        // a late position report must not restart or move anything
        #expect(!r.session.isPlaying && r.engine.rate.isPaused)
        #expect(r.session.playhead == Time(3, 30))
        r.session.stopPlayback()                                // idempotent
        #expect(!r.session.isPlaying)
    }

    @Test func seekAndScrubWhilePlayingStopPlayback() throws {
        let r = try Rig()
        r.session.playPause()
        r.session.stopPlayback()
        r.session.seek(to: Time(30, 30))
        #expect(!r.session.isPlaying && r.engine.rate.isPaused && r.session.playhead == Time(30, 30))
        r.session.playPause()
        #expect(r.session.isPlaying)
        r.session.stopPlayback()
        r.session.beginScrub()
        r.session.scrub(to: Time(15, 30))
        r.session.endScrub()
        #expect(!r.session.isPlaying && r.session.playhead == Time(15, 30))
    }

    @Test func transportCommands() throws {
        let r = try Rig()
        r.session.playPause()
        #expect(r.engine.rate == .forward && r.session.isPlaying)
        r.session.playPause()
        #expect(r.engine.rate.isPaused && !r.session.isPlaying)
        r.session.apply(shuttle: .setRate(PlaybackRate(2)))
        #expect(r.engine.rate == PlaybackRate(2))
        r.session.apply(shuttle: .setRate(.zero))
        #expect(r.engine.rate.isPaused)
        r.session.seek(to: Time(10, 30))
        r.session.stepFrames(-1)
        #expect(r.session.playhead == Time(9, 30))
        r.session.goToEnd()
        #expect(r.session.playhead == s(4))
        r.session.goToStart()
        #expect(r.session.playhead == .zero)
    }

    @Test func editPointNavigation() throws {
        let r = try Rig()
        r.session.seek(to: Time(1, 1))
        r.session.goToNextEditPoint()
        #expect(r.session.playhead == s(2))
        r.session.goToNextEditPoint()
        #expect(r.session.playhead == s(4))
        r.session.goToPreviousEditPoint()
        #expect(r.session.playhead == s(2))
    }

    // MARK: Commands

    @Test func deleteLeavesGapRippleClosesIt() throws {
        let r = try Rig()
        r.session.select(clips: [r.a.id])
        r.session.deleteSelection(ripple: false)
        #expect(r.timeline.tracks[0].clips.map(\.id) == [r.b.id])
        #expect(r.timeline.tracks[0].clips[0].start == s(2))
        #expect(r.session.selection.isEmpty)
        r.session.undo()
        r.session.select(clips: [r.a.id])
        r.session.deleteSelection(ripple: true)
        #expect(r.timeline.tracks[0].clips[0].start == .zero)
        #expect(r.session.undoName == "Ripple Delete")
    }

    @Test func razorSplitsClipsUnderPlayheadOnSelectedTracks() throws {
        let r = try Rig()
        r.session.seek(to: Time(1, 1))
        r.session.addEditAtPlayhead()
        #expect(r.timeline.tracks[0].clips.count == 3)
        #expect(r.timeline.tracks[0].clips[1].start == s(1))
        #expect(r.session.undoName == "Add Edit")
    }

    @Test func inOutMarksAndGoTo() throws {
        let r = try Rig()
        r.session.seek(to: s(1)); r.session.markIn()
        #expect(r.timeline.inOut?.start == s(1))
        r.session.seek(to: s(3)); r.session.markOut()
        #expect(r.timeline.inOut == TimeRange(start: s(1), end: s(3)))
        r.session.seek(to: .zero); r.session.goToOut()
        #expect(r.session.playhead == s(3))
        r.session.goToIn()
        #expect(r.session.playhead == s(1))
        r.session.clearInOut()
        #expect(r.timeline.inOut == nil)
    }

    @Test func markOutBeforeInMovesInToo() throws {
        let r = try Rig()
        r.session.seek(to: s(3)); r.session.markIn()
        r.session.seek(to: s(1)); r.session.markOut()
        let io = try #require(r.timeline.inOut)
        #expect(io.start < io.end)
        #expect(io.end == s(1))
    }

    @Test func addMarkerAtPlayhead() throws {
        let r = try Rig()
        r.session.seek(to: s(2))
        r.session.addMarkerAtPlayhead()
        #expect(r.timeline.markers.map(\.time) == [s(2)])
    }

    @Test func liftAndExtractRangeUseInOut() throws {
        let r = try Rig()
        r.session.seek(to: s(1)); r.session.markIn()
        r.session.seek(to: s(3)); r.session.markOut()
        r.session.liftRange()
        #expect(r.timeline.tracks[0].clips.map(\.timeline) == [TimeRange(start: .zero, end: s(1)), TimeRange(start: s(3), end: s(4))])
        r.session.undo()
        r.session.extractRange()
        #expect(r.timeline.tracks[0].clips.map(\.timeline) == [TimeRange(start: .zero, end: s(1)), TimeRange(start: s(1), end: s(2))])
    }

    @Test func rippleTrimToPlayheadShortensTheSequence() throws {
        let r = try Rig()
        r.session.seek(to: s(1))
        r.session.rippleTrimToPlayhead(.tail)
        #expect(r.timeline.duration == s(3))
        #expect(r.session.undoName == "Ripple Trim Next Edit")
    }

    @Test func addEditToAllTracksIgnoresSelection() throws {
        let r = try Rig()
        r.session.select(clips: [r.b.id])
        r.session.seek(to: s(1))
        r.session.addEditAtPlayhead(allTracks: true)
        #expect(r.timeline.tracks[0].clips.count == 3)
    }

    @Test func newSequenceMatchesFormatAndBecomesActive() throws {
        let r = try Rig()
        let id = r.session.addSequence()
        #expect(id != r.t.id)
        #expect(r.session.activeTimelineID == id)
        #expect(r.session.project.timelines.count == 2)
        #expect(r.timeline.format == r.t.format)
        #expect(r.timeline.name == "Sequence 02")
        #expect(r.engine.timeline?.id == id)
        #expect(r.session.project.rootBin.contains(.sequence(id)))
        r.session.undo()
        #expect(r.session.activeTimelineID == r.t.id)
        #expect(r.engine.timeline == r.t)
    }

    // MARK: Placing media

    private func mediaRef(_ name: String, dur: Int64 = 4, audio: Bool = true, w: Int = 3840, h: Int = 2160,
                          fd: Time = Time(1001, 30000)) -> MediaRef {
        let v = VideoTrackInfo(width: w, height: h, codec: "avc1", bitDepth: 10, chroma: "4:2:2",
                               nominalFrameDuration: fd, isVariableFrameRate: false)
        let a = audio ? AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm") : nil
        return MediaRef(name: name, path: "/nonexistent/\(name).mov", fingerprint: MediaFingerprint(size: 1),
                        duration: s(dur), info: MediaInfo(duration: s(dur), video: v, audio: a))
    }

    @Test func placeMediaOverwritesAtPlayheadWithLinkedAV() throws {
        let r = try Rig()
        let m = mediaRef("A")
        r.session.perform("Import") { $0.add(m) }
        r.session.seek(to: s(10))
        #expect(r.session.placeMedia([m.id], mode: .overwrite))
        let v = try #require(r.timeline.tracks.first { $0.kind == .video }?.clips.last)
        let a = try #require(r.timeline.tracks.first { $0.kind == .audio }?.clips.first)
        #expect(v.media == m.id && v.start == s(10) && v.source == TimeRange(start: .zero, duration: s(4)))
        #expect(v.link != nil && v.link == a.link)
        #expect(r.session.undoName == "Overwrite")
    }

    @Test func placeMediaUsesSourceMarksAndGoesSequentially() throws {
        let r = try Rig()
        let m = mediaRef("A"), n = mediaRef("B", dur: 3, audio: false)
        r.session.perform("Import") { $0.add(m); $0.add(n); $0.setSourceIn(s(1), for: m.id); $0.setSourceOut(s(3), for: m.id) }
        r.session.seek(to: s(10))
        #expect(r.session.placeMedia([m.id, n.id], mode: .overwrite))
        let clips = r.timeline.tracks.first { $0.kind == .video }!.clips.filter { $0.start >= s(10) }
        #expect(clips.map(\.start) == [s(10), s(12)])
        #expect(clips[0].source == TimeRange(start: s(1), end: s(3)))
        #expect(r.timeline.tracks.first { $0.kind == .audio }!.clips.count == 1)   // B has no audio
    }

    @Test func firstClipIntoEmptyTimelineAdoptsItsFormat() throws {
        var p = EditorSession.makeUntitled()
        let m = mediaRef("A", w: 3840, h: 2160, fd: Time(1001, 30000))
        p.add(m)
        p.timelines[0].format = SequenceFormat(width: 1280, height: 720, frameDuration: Time(1, 25))
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        #expect(session.placeMedia([m.id], mode: .overwrite))
        let f = try #require(session.activeTimeline?.format)
        #expect(f.width == 3840 && f.height == 2160 && f.frameDuration == Time(1001, 30000))
    }

    @Test func portraitPhoneClipMakesPortraitSequence() throws {
        var p = EditorSession.makeUntitled()
        let v = VideoTrackInfo(width: 1920, height: 1080, codec: "hvc1", bitDepth: 10, chroma: "4:2:0",
                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false, rotation: 90)
        let m = MediaRef(name: "phone", path: "/nonexistent/phone.mov", fingerprint: MediaFingerprint(size: 1),
                         duration: s(4), info: MediaInfo(duration: s(4), video: v))
        p.add(m)
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        #expect(session.placeMedia([m.id], mode: .overwrite))
        let f = try #require(session.activeTimeline?.format)
        #expect(f.width == 1080 && f.height == 1920 && f.frameDuration == Time(1, 30))
        #expect(ProjectPanelModel.formatString(m).hasPrefix("1080×1920"))
    }

    @Test func stillImagePlacesWithDefaultLengthAndTrimsFreely() throws {
        var p = EditorSession.makeUntitled()
        let info = MediaInfo(duration: MediaInfo.defaultStillDuration,
                             video: VideoTrackInfo(width: 4000, height: 3000, codec: "image", bitDepth: 8, chroma: "4:4:4",
                                                   nominalFrameDuration: Time(1, 30), isVariableFrameRate: false), isStill: true)
        let m = MediaRef(name: "photo.jpg", path: "/nonexistent/photo.jpg", fingerprint: MediaFingerprint(size: 1),
                         duration: info.duration, info: info)
        p.add(m)
        p.timelines[0].format = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1001, 30000))
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        #expect(session.placeMedia([m.id], mode: .overwrite))
        let t = try #require(session.activeTimeline)
        let c = try #require(t.tracks.first { $0.kind == .video }?.clips.first)
        #expect(c.isStill && c.timeline.duration == s(5) && c.mediaDuration == nil)
        #expect(t.tracks.first { $0.kind == .audio }?.clips.isEmpty == true)
        #expect(t.format.width == 4000 && t.format.frameDuration == Time(1001, 30000))   // size from the still, rate kept
        #expect(ProjectPanelModel.formatString(m) == "4000×3000 Still image")
    }

    @Test func placedClipGetsFitScaleAndSetToFrameSizeRestoresIt() throws {
        let r = try Rig()
        let big = mediaRef("Big", audio: false, w: 3840, h: 2160)
        r.session.perform("Import") { $0.add(big) }
        let format = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))
        r.session.perform("Seq") { p in p.timelines[0].format = format }
        #expect(r.session.placeMedia([big.id], at: .zero, mode: .overwrite))
        let c = try #require(r.timeline.tracks.first { $0.kind == .video }?.clips.first { $0.media == big.id })
        #expect(abs(c.animation.scale.value.x - 0.28125) < 1e-12)           // 4K landscape in 1080 x 1920, fits whole
        // User sets 100 %, then Set to Frame Size brings the fit value back in one undo step.
        var edited = c
        edited.animation.scale = AnimatedProperty(Vec2(1, 1))
        r.session.replaceClip(edited, name: "Scale", continuesGesture: false)
        r.session.select(clips: [c.id])
        #expect(r.session.setToFrameSize())
        let back = try #require(r.timeline.tracks.first { $0.kind == .video }?.clips.first { $0.id == c.id })
        #expect(abs(back.animation.scale.value.x - 0.28125) < 1e-12)
        #expect(r.session.undoName == "Set to Frame Size")
        #expect(!r.session.setToFrameSize())                                 // already at the fit value: no new step
        r.session.undo()
        let undone = try #require(r.timeline.tracks.first { $0.kind == .video }?.clips.first { $0.id == c.id })
        #expect(undone.animation.scale.value == Vec2(1, 1))
    }

    @Test func secondClipKeepsTheSequenceFormat() throws {
        let r = try Rig()
        let m = mediaRef("A", w: 3840, h: 2160)
        r.session.perform("Import") { $0.add(m) }
        #expect(r.session.placeMedia([m.id], mode: .overwrite))
        #expect(r.timeline.format == r.t.format)      // timeline already had clips
    }

    @Test func insertModeRipples() throws {
        let r = try Rig()
        let m = mediaRef("A", dur: 2, audio: false)
        r.session.perform("Import") { $0.add(m) }
        r.session.seek(to: s(2))
        #expect(r.session.placeMedia([m.id], mode: .insert))
        #expect(r.timeline.tracks[0].clips.map(\.start) == [s(0), s(2), s(4)])
        #expect(r.session.undoName == "Insert")
    }

    @Test func unknownMediaPlacesNothing() throws {
        let r = try Rig()
        #expect(!r.session.placeMedia([UUID()], mode: .overwrite))
        #expect(!r.session.canUndo)
    }

    @Test func stepFramesSeeksInsteadOfEngineStep() throws {
        let r = try Rig()
        r.session.seek(to: Time(10, 30))
        r.session.stepFrames(-3)
        #expect(r.engine.calls.last == .seek(Time(7, 30)))
        #expect(!r.engine.calls.contains(.step(-3)))
        #expect(r.session.playhead == Time(7, 30))
    }

    @Test func dropStartSnapsToTheNewFormatAfterAdoptingIt() throws {
        var p = EditorSession.makeUntitled()
        let m = mediaRef("A", fd: Time(1001, 30000))
        p.add(m)
        p.timelines[0].format = SequenceFormat(width: 1280, height: 720, frameDuration: Time(1, 25))
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        #expect(session.placeMedia([m.id], at: Time(3, 25), mode: .overwrite))
        let v = try #require(session.activeTimeline?.tracks.first { $0.kind == .video }?.clips.first)
        #expect(v.start == Time(3, 25).snapped(to: Time(1001, 30000)))
    }

    @Test func saveAsRefreshesTheCrashMarker() async throws {
        let r = try Rig()
        let url = r.dir.appendingPathComponent("M.ssproj")
        try await r.session.saveAs(to: url)
        let info = SessionMarker(store: r.store).infos(projectID: r.session.project.id).first
        #expect(info?.projectPath == url.path)
    }

    @Test func autosaveForAReplacedProjectIsDiscarded() async throws {
        let r = try Rig()
        let slow = AutosaveStore(base: r.dir.appendingPathComponent("Slow"), policy: r.store.policy, writer: { p, u in
            Thread.sleep(forTimeInterval: 0.3)
            try ProjectFile.write(p, to: u)
        })
        let (p, _, a, _) = try makeProject()
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: slow, clock: { Date() })
        try session.performTimeline("Delete") { try $0.lift([a.id]) }
        async let written = session.tickAutosave()
        try await Task.sleep(for: .milliseconds(80))
        session.newProject()
        #expect(await written == false)
        #expect(session.lastAutosave == nil)
    }

    @Test func activeTimelineSwitchUpdatesTheAudioSampleRate() throws {
        let (p0, t, _, _) = try makeProject()
        var p = p0
        var other = Timeline(name: "44k", format: SequenceFormat(frameDuration: fd, audioSampleRate: 44_100))
        other.tracks = [Track(kind: .video)]
        p.timelines.append(other)
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        #expect(session.media.sampleRate == t.format.audioSampleRate)
        session.setActiveTimeline(other.id)
        #expect(session.media.sampleRate == 44_100)
    }

    @Test func gestureCommitReplaysEditsAsOneStep() throws {
        let r = try Rig()
        let moved = try TimelineEdit.apply([.move(r.b.id, to: s(6), track: nil)], to: r.t)
        let commit = TimelineCommit(timeline: moved, edits: [.move(r.b.id, to: s(6), track: nil)],
                                    undoName: "Move Clip", selection: [r.b.id])
        r.session.commit(commit)
        #expect(r.timeline == moved)
        #expect(r.session.selection == [r.b.id])
        #expect(r.session.undoName == "Move Clip")
        r.session.undo()
        #expect(r.timeline == r.t)
    }

    @Test func replaceClipCoalescesWithinAGesture() throws {
        let r = try Rig()
        var c = r.a
        c.name = "x1"
        r.session.replaceClip(c, name: "Edit Effect", continuesGesture: false)
        c.name = "x2"
        r.session.replaceClip(c, name: "Edit Effect", continuesGesture: true)
        #expect(r.timeline.tracks[0].clips[0].name == "x2")
        r.session.undo()
        #expect(r.timeline.tracks[0].clips[0].name == r.a.name)
        #expect(!r.session.canUndo)
    }

    // MARK: Open / save

    @Test func saveAsThenOpenRoundTrips() async throws {
        let r = try Rig()
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        let url = r.dir.appendingPathComponent("Edit.ssproj")
        try await r.session.saveAs(to: url)
        #expect(r.session.fileURL == url)
        let other = EditorSession(engine: StubProgramEngine(), autosaveStore: r.store)
        try await other.open(url: url)
        #expect(other.project.timelines == r.session.project.timelines)
        #expect(!other.isDirty)
        #expect(other.fileURL == url)
        #expect(other.engine is StubProgramEngine)
    }

    @Test func saveWithoutURLThrows() async throws {
        let r = try Rig()
        await #expect(throws: EditorSession.SaveError.noFileURL) { try await r.session.save() }
    }

    @Test func savesAreSerialisedThroughTheQueue() async throws {
        let order = OrderLog()
        let queue = ProjectSaveQueue(writer: { p, _ in order.add(p.name) })
        let (p, _, _, _) = try makeProject()
        let session = EditorSession(project: p, engine: StubProgramEngine(), saveQueue: queue,
                                    autosaveStore: AutosaveStore(base: tempDir()))
        let url = tempDir().appendingPathComponent("x.ssproj")
        try await session.saveAs(to: url)
        session.perform("Rename") { $0.name = "Two" }
        try await session.save()
        #expect(order.items == ["P", "Two"])
    }

    // MARK: Autosave and recovery

    @Test func autosaveTimerTickWritesSnapshotOnlyWhenDirtyAndDue() async throws {
        let r = try Rig()
        #expect(await r.session.tickAutosave() == false)              // clean
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        #expect(await r.session.tickAutosave() == true)               // dirty, never autosaved
        #expect(r.store.versions(for: r.session.project.id).count == 1)
        r.clock.now += 100
        #expect(await r.session.tickAutosave() == false)              // not due
        r.clock.now += 250
        #expect(await r.session.tickAutosave() == true)               // 350 s later
        #expect(r.store.versions(for: r.session.project.id).count == 2)
        let saved = try r.store.read(r.store.versions(for: r.session.project.id)[0])
        #expect(saved.timelines == r.session.project.timelines)
    }

    @Test func recoveryScanFindsCrashedSessionAndRecoversAsUntitledCopy() async throws {
        let r = try Rig()
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        _ = await r.session.tickAutosave()
        let scanner = RecoveryScanner(store: r.store, isProcessAlive: { _ in false })
        let found = EditorSession.recoveryCandidates(scanner: scanner)
        #expect(found.count == 1)
        let recovered = EditorSession(engine: StubProgramEngine(), autosaveStore: r.store)
        try await recovered.recover(found[0], scanner: scanner)
        #expect(recovered.project.name == "P (Recovered)")
        #expect(recovered.project.id != r.session.project.id)
        #expect(recovered.fileURL == nil)
        #expect(recovered.isDirty)
        #expect(recovered.project.timelines == r.session.project.timelines)
        #expect(EditorSession.recoveryCandidates(scanner: scanner).isEmpty)
    }

    @Test func cleanCloseRemovesSessionMarker() throws {
        let r = try Rig()
        let marker = SessionMarker(store: r.store)
        #expect(marker.infos(projectID: r.session.project.id).count == 1)
        r.session.close()
        #expect(marker.infos(projectID: r.session.project.id).isEmpty)
    }
}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String] = []
    var items: [String] { lock.withLock { _items } }
    func add(_ s: String) { lock.withLock { _items.append(s) } }
}

// MARK: Media resolver

private final class FakeDemux: Demuxing, @unchecked Sendable {
    let index = SampleIndex(entries: [])
    let formatDescription: CMFormatDescription
    init() {
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 16, height: 16,
                                       extensions: nil, formatDescriptionOut: &fd)
        formatDescription = fd!
    }
    func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer] { [] }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

@Suite struct ProjectMediaResolverTests {
    private func ref(_ path: String) -> MediaRef {
        MediaRef(name: "m", path: path, fingerprint: MediaFingerprint(size: 1))
    }

    private func resolver(existing: Set<String>, noAudio: Bool = false, opens: Counter = Counter()) -> ProjectMediaResolver {
        ProjectMediaResolver(
            demuxer: { _ in opens.bump(); return FakeDemux() },
            audio: { _, _ in
                if noAudio { throw MediaError.unreadable }
                return MemoryAudioSource(mono: [0, 0])
            },
            fileExists: { existing.contains($0) })
    }

    @Test func unknownMediaAndOffline() throws {
        let m = ref("/missing/a.mov")
        let r = resolver(existing: [])
        r.update([m])
        let unknown = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        #expect(throws: MediaResolveError.unknownMedia(unknown)) { try r.demuxer(for: unknown) }
        #expect(throws: MediaResolveError.offline(m.id, path: "/missing/a.mov")) { try r.demuxer(for: m.id) }
        #expect(throws: MediaResolveError.offline(m.id, path: "/missing/a.mov")) { try r.audio(for: m.id) }
        #expect(r.isOffline(m.id))
    }

    @Test func lookupOpensLazilyOnceAndCaches() throws {
        let m = ref("/ok/a.mov")
        let opens = Counter()
        let r = resolver(existing: [m.path], opens: opens)
        r.update([m])
        let a = try r.demuxer(for: m.id)
        let b = try r.demuxer(for: m.id)
        #expect(a is FakeDemux)
        #expect(a as AnyObject === b as AnyObject)
        #expect(opens.value == 1)
        #expect(try r.audio(for: m.id) is MemoryAudioSource)
    }

    @Test func prepareWarmsTheCache() async throws {
        let m = ref("/ok/a.mov")
        let opens = Counter()
        let r = resolver(existing: [m.path], opens: opens)
        r.update([m])
        let ready = await r.prepare([m.id])
        #expect(ready == [m.id])
        _ = try r.demuxer(for: m.id)
        #expect(opens.value == 1)
    }

    @Test func videoOnlyFileHasNoAudio() async throws {
        let m = ref("/ok/v.mov")
        let r = resolver(existing: [m.path], noAudio: true)
        r.update([m])
        #expect(await r.prepare([m.id]) == [m.id])
        #expect(throws: MediaResolveError.noAudio(m.id)) { try r.audio(for: m.id) }
    }

    @Test func prepareSkipsOfflineItems() async {
        let m = ref("/missing/b.mov")
        let r = resolver(existing: [])
        r.update([m])
        #expect(await r.prepare([m.id]).isEmpty)
    }

    @Test func prepareAndLookupShareOneOpen() async throws {
        let m = ref("/ok/a.mov")
        let opens = Counter()
        let r = ProjectMediaResolver(demuxer: { _ in opens.bump(); try await Task.sleep(for: .milliseconds(200)); return FakeDemux() },
                                     audio: { _, _ in MemoryAudioSource(mono: [0]) }, fileExists: { _ in true })
        r.update([m])
        async let prepared = r.prepare([m.id])
        try await Task.sleep(for: .milliseconds(40))
        let viaLookup = Task.detached { try r.demuxer(for: m.id) }
        let d = try await viaLookup.value
        #expect(await prepared == [m.id])
        #expect(opens.value == 1)
        #expect(try r.demuxer(for: m.id) as AnyObject === d as AnyObject)
    }

    @Test func updateDuringAnOpenDiscardsTheStaleResult() async throws {
        var m = ref("/ok/a.mov")
        let opens = Counter()
        let r = ProjectMediaResolver(demuxer: { _ in opens.bump(); try await Task.sleep(for: .milliseconds(200)); return FakeDemux() },
                                     audio: { _, _ in MemoryAudioSource(mono: [0]) }, fileExists: { _ in true })
        r.update([m])
        let id = m.id
        async let prepared = r.prepare([id])
        try await Task.sleep(for: .milliseconds(50))
        m.path = "/ok/b.mov"
        r.update([m])
        #expect(await prepared.isEmpty)
        _ = try r.demuxer(for: m.id)
        #expect(opens.value == 2)
    }

    @Test func relinkDropsCachedSources() async throws {
        var m = ref("/ok/a.mov")
        let opens = Counter()
        let r = resolver(existing: ["/ok/a.mov", "/ok/b.mov"], opens: opens)
        r.update([m])
        _ = try r.demuxer(for: m.id)
        m.path = "/ok/b.mov"
        r.update([m])
        _ = try r.demuxer(for: m.id)
        #expect(opens.value == 2)
    }
}

@MainActor @Suite struct LazyColorDetectionTests {
    @Test func openFillsDetectedColorOnceOutsideUndo() async throws {
        let dir = tempDir()
        let file = dir.appendingPathComponent("clip.mov")
        try Data([0]).write(to: file)
        let info = MediaInfo(duration: s(2), video: VideoTrackInfo(width: 1920, height: 1080, codec: "hvc1", bitDepth: 10,
                             chroma: "4:2:0", nominalFrameDuration: fd, isVariableFrameRate: false))
        #expect(info.needsColorDetection)
        let ref = MediaRef(name: "clip.mov", path: file.path, fingerprint: MediaFingerprint(size: 1), duration: s(2), info: info)
        var p = Project(name: "P", timelines: [Timeline(name: "T", frameDuration: fd, tracks: [Track(kind: .video)])])
        p.add(ref)
        let session = EditorSession()
        session.colorDetector = { _ in (.sLog3SGamut3Cine, "Look") }
        session.newProject(p)
        for _ in 0..<100 where session.project.media.first?.info?.needsColorDetection == true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.project.media.first?.info?.detectedColorSpace == .sLog3SGamut3Cine)
        #expect(session.project.media.first?.info?.embeddedLUTName == "Look")
        #expect(!session.isDirty)
        #expect(!session.canUndo)
    }
}
