import CoreMedia
import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession

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
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("sq-session-\(UUID().uuidString)", isDirectory: true)
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

@MainActor @Suite struct MarkClipTests {
    @Test func marksClipUnderPlayhead() throws {
        let r = try Rig()
        let clip = r.t.tracks.flatMap(\.clips).first!
        r.session.seek(to: clip.start + r.timeline.frameDuration)
        r.session.markClip()
        #expect(r.timeline.inOut != nil)
        #expect(r.timeline.inOut!.start <= clip.start && r.timeline.inOut!.end >= clip.timeline.end)
        #expect(r.session.undoName == "Mark Clip")
    }
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

    // MARK: Legacy .ssproj

    @Test func opensALegacyProject() async throws {
        let r = try Rig()
        let old = r.dir.appendingPathComponent("Old.ssproj")
        try ProjectFile.write(r.session.project, to: old)
        try await r.session.open(url: old)
        #expect(r.session.fileURL == old)
        #expect(!r.session.isDirty)
        #expect(r.session.lastError == nil)
    }

    @Test func savingALegacyProjectWritesASiblingSqproj() async throws {
        let r = try Rig()
        let old = r.dir.appendingPathComponent("Old.ssproj")
        try ProjectFile.write(r.session.project, to: old)
        try await r.session.open(url: old)
        let before = try Data(contentsOf: old.appendingPathComponent("project.json"))
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        try await r.session.save()
        let new = r.dir.appendingPathComponent("Old.sqproj")
        #expect(r.session.fileURL?.standardizedFileURL.path == new.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: new.path))
        #expect(!r.session.isDirty)
        #expect(try Data(contentsOf: old.appendingPathComponent("project.json")) == before)
        #expect(r.session.lastError?.contains("Old.sqproj") == true)
        // The second save goes to the new file, without a note.
        r.session.clearError()
        try r.session.performTimeline("Delete") { try $0.lift([r.b.id]) }
        try await r.session.save()
        #expect(r.session.fileURL?.standardizedFileURL.path == new.standardizedFileURL.path)
        #expect(r.session.lastError == nil)
        #expect(try ProjectFile.read(from: new).timelines[0].tracks[0].clips.isEmpty)
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
        try await r.session.saveAs(to: r.dir.appendingPathComponent("a.sqproj"))
        #expect(!r.session.isDirty)
        try r.session.performTimeline("Delete") { try $0.lift([r.b.id]) }
        #expect(r.session.isDirty)
    }

    @Test func editAfterSaveSnapshotStaysDirty() async throws {
        let r = try Rig()
        try await r.session.saveAs(to: r.dir.appendingPathComponent("a.sqproj"))
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
        // Undo reveals the change: the restored clip becomes the selection.
        #expect(r.session.selection == [r.a.id])
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
        r.session.goToEnd()      // MON-16: parks on the last frame, not one past it
        #expect(r.session.playhead == s(4) - Time(1, 30))
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
        let fd = r.timeline.frameDuration
        #expect(r.timeline.inOut == TimeRange(start: s(1), end: s(3) + fd))      // Out includes its own frame
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
        #expect(io.end == s(1) + r.timeline.frameDuration)
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
        let fd = r.timeline.frameDuration
        r.session.liftRange()
        #expect(r.timeline.tracks[0].clips.map(\.timeline) == [TimeRange(start: .zero, end: s(1)), TimeRange(start: s(3) + fd, end: s(4))])
        r.session.undo()
        r.session.extractRange()
        #expect(r.timeline.tracks[0].clips.map(\.timeline) == [TimeRange(start: .zero, end: s(1)), TimeRange(start: s(1), end: s(2) - fd)])
    }

    @Test func rippleTrimToPlayheadShortensTheSequence() throws {
        let r = try Rig()
        r.session.seek(to: s(1))
        r.session.rippleTrimToPlayhead(.tail)
        #expect(r.timeline.duration == s(3))
        #expect(r.session.undoName == "Ripple Trim Next Edit")
    }

    @Test func rippleTrimHeadMovesPlayheadToTheNewEditPoint() throws {
        let r = try Rig()
        r.session.seek(to: s(3))                      // inside b [2,4)
        r.session.rippleTrimToPlayhead(.head)         // b keeps its start, the part before 3 s is cut
        #expect(r.timeline.tracks[0].clips[1].timeline == TimeRange(start: s(2), end: s(3)))
        #expect(r.session.playhead == s(2))           // same picture as before, now at the edit point
        #expect(r.engine.position == s(2))
    }

    @Test func rippleTrimLimitedByAnotherTrackSaysWhich() throws {
        let r = try Rig()
        try r.session.performTimeline("Setup") { t in
            for (a, b) in [(Time(1, 1), Time(5, 2)), (Time(3, 1), Time(4, 1))] {
                try t.tracks[1].overwrite(Clip(name: "au", media: UUID(), kind: .audio,
                                               source: TimeRange(start: .zero, duration: b - a), start: a))
            }
        }
        r.session.seek(to: s(1))
        r.session.rippleTrimToPlayhead(.tail)                       // A1's [1, 2.5) leaves only 0.5 s of room
        #expect(r.timeline.tracks[0].clips[0].timeline.end == Time(3, 2))
        #expect(r.session.lastError == "Trim limited by clip on A1")
    }

    @Test func rippleTrimTailKeepsThePlayhead() throws {
        let r = try Rig()
        r.session.seek(to: s(1))
        r.session.rippleTrimToPlayhead(.tail)
        #expect(r.session.playhead == s(1))
    }

    @Test func refusedRippleTrimLeavesThePlayhead() throws {
        let r = try Rig()
        r.session.seek(to: s(9))                      // past every clip
        r.session.rippleTrimToPlayhead(.head)
        #expect(r.session.playhead == s(9))
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

    @Test func configuredSequenceKeepsItsFormatWhenEmptyAgain() throws {
        var p = EditorSession.makeUntitled()
        let m = mediaRef("A", w: 3840, h: 2160, fd: Time(1001, 30000))
        p.add(m)
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        let vertical = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 25))
        #expect(session.setSequenceFormat(vertical))
        #expect(session.placeMedia([m.id], mode: .overwrite))
        #expect(session.activeTimeline?.format == vertical)
        // New Sequence is configured as well.
        let id = session.addSequence(format: SequenceFormat(width: 640, height: 360, frameDuration: Time(1, 24)))
        #expect(session.placeMedia([m.id], mode: .overwrite))
        #expect(session.project.timelines.first { $0.id == id }?.format.width == 640)
    }

    @Test func dropOnV2PlacesLinkedAudioOnA2AndCreatesMissingTracks() throws {
        var p = EditorSession.makeUntitled()
        let m = mediaRef("A")
        p.add(m)
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        let t0 = try #require(session.activeTimeline)
        let v = t0.tracks.filter { $0.kind == .video }, a = t0.tracks.filter { $0.kind == .audio }
        #expect(session.placeMedia([m.id], at: .zero, videoTrack: v[1].id, mode: .overwrite))
        let t1 = try #require(session.activeTimeline)
        #expect(t1.track(v[1].id)?.clips.count == 1)
        #expect(t1.track(a[1].id)?.clips.count == 1)
        #expect(t1.track(a[0].id)?.clips.isEmpty == true)
        // A drop on V3 with only two audio tracks would create A4 when missing; here A3 exists.
        #expect(session.placeMedia([m.id], at: s(10), videoTrack: v[2].id, mode: .overwrite))
        #expect(session.activeTimeline?.track(a[2].id)?.clips.count == 1)
        // Fewer audio tracks than video tracks: the missing mirrored track is created.
        try session.performTimeline("Remove") { $0.tracks.removeAll { $0.id == a[2].id } }
        #expect(session.placeMedia([m.id], at: s(20), videoTrack: v[2].id, mode: .overwrite))
        let t2 = try #require(session.activeTimeline)
        #expect(t2.tracks.filter { $0.kind == .audio }.count == 3)
        let created = try #require(t2.audioTrack(atOrdinal: 2))
        #expect(t2.track(created)?.clips.count == 1)
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
        #expect(c.isStill && c.timeline.duration == Time(1001, 30000) * 150 && c.mediaDuration == nil)   // 5 s in whole frames
        #expect(t.tracks.first { $0.kind == .audio }?.clips.isEmpty == true)
        #expect(t.format.width == 4000 && t.format.frameDuration == Time(1001, 30000))   // size from the still, rate kept
        #expect(ProjectPanelModel.formatString(m) == "4000×3000 Still image")
    }

    @Test func stillImageIntoProjectWithoutSequenceCreatesOneFromThePhoto() throws {
        var p = Project(name: "p", timelines: [])
        let info = MediaInfo(duration: MediaInfo.defaultStillDuration,
                             video: VideoTrackInfo(width: 4000, height: 3000, codec: "image", bitDepth: 8, chroma: "4:4:4",
                                                   nominalFrameDuration: Time(1, 30), isVariableFrameRate: false), isStill: true)
        let m = MediaRef(name: "photo.jpg", path: "/nonexistent/photo.jpg", fingerprint: MediaFingerprint(size: 1),
                         duration: info.duration, info: info)
        p.add(m)
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        #expect(session.activeTimeline == nil)
        #expect(session.placeMedia([m.id], mode: .overwrite))
        let t = try #require(session.activeTimeline)
        #expect(t.format.width == 4000 && t.format.height == 3000)
        let c = try #require(t.tracks.first { $0.kind == .video }?.clips.first)
        #expect(c.isStill && c.media == m.id && c.timeline.duration > .zero)
    }

    // FILMCRAFT-PRS #833 #863 #938: a drop of several files with no sequence open makes ONE sequence in the first item's
    // size and rate and places all of them on it, back to back.
    @Test func dropOfSeveralFilesWithoutSequenceMakesOneSequenceFromTheFirst() throws {
        var p = Project(name: "p", timelines: [])
        let a = mediaRef("A", dur: 2, w: 1080, h: 1920, fd: Time(1, 25)), b = mediaRef("B", dur: 3, w: 3840, h: 2160)
        p.add(a); p.add(b)
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        #expect(session.placeMedia([a.id, b.id], at: .zero, mode: .overwrite))
        #expect(session.project.timelines.count == 1)
        let t = try #require(session.activeTimeline)
        #expect(t.format.width == 1080 && t.format.height == 1920 && t.format.frameDuration == Time(1, 25))
        let v = try #require(t.tracks.first { $0.kind == .video }).clips.sorted { $0.timeline.start < $1.timeline.start }
        #expect(v.map(\.media) == [a.id, b.id])
        #expect(v[1].timeline.start == v[0].timeline.end)
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
        #expect(r.session.undoName == "Fit to Frame")
        #expect(!r.session.setToFrameSize())                                 // already at the fit value: no new step
        r.session.undo()
        let undone = try #require(r.timeline.tracks.first { $0.kind == .video }?.clips.first { $0.id == c.id })
        #expect(undone.animation.scale.value == Vec2(1, 1))
    }

    @Test func setToFillFrameCoversTheFrameInOneUndoStep() throws {
        let r = try Rig()
        let big = mediaRef("Big", audio: false, w: 3840, h: 2160)
        r.session.perform("Import") { $0.add(big) }
        r.session.perform("Seq") { p in p.timelines[0].format = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)) }
        #expect(r.session.placeMedia([big.id], at: .zero, mode: .overwrite))
        let c = try #require(r.timeline.tracks.first { $0.kind == .video }?.clips.first { $0.media == big.id })
        r.session.select(clips: [c.id])
        #expect(r.session.setToFillFrame())
        let filled = try #require(r.timeline.tracks.first { $0.kind == .video }?.clips.first { $0.id == c.id })
        #expect(abs(filled.animation.scale.value.x - 1920.0 / 2160.0) < 1e-12)   // fit would be 0.28125
        #expect(r.session.undoName == "Fill Frame")
        #expect(!r.session.setToFillFrame())
        r.session.undo()
        let back = try #require(r.timeline.tracks.first { $0.kind == .video }?.clips.first { $0.id == c.id })
        #expect(abs(back.animation.scale.value.x - 0.28125) < 1e-12)
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
        let url = r.dir.appendingPathComponent("M.sqproj")
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

    /// Mouse up ends the gesture: its step is final, and a later edit that lands on the gesture's start is a step of its
    /// own, not a cancel that brings old redo steps back.
    @Test func anEndedGestureIsFinal() throws {
        let r = try Rig()
        var named = r.a
        named.name = "first"
        r.session.replaceClip(named, name: "Rename", continuesGesture: false)
        var again = named
        again.name = "second"
        r.session.replaceClip(again, name: "Rename Again", continuesGesture: false)
        r.session.undo()
        let depth = r.session.undoStepDepth
        var c = named
        c.name = "drag 1"
        r.session.replaceClip(c, name: "Item Range", continuesGesture: false)
        r.session.endGesture()
        r.session.replaceClip(named, name: "Item Range", continuesGesture: true)
        #expect(r.session.undoStepDepth == depth + 2)
        #expect(!r.session.canRedo)
        r.session.undo()
        #expect(r.timeline.tracks[0].clips[0].name == "drag 1")
    }

    /// A drag that is canceled (Esc, the window gone, the window no longer key) sends its starting clip once more:
    /// no undo step is left and what could be redone before the drag still can.
    @Test func aCanceledGestureLeavesNoStepAndKeepsRedo() throws {
        let r = try Rig()
        var named = r.a
        named.name = "first"
        r.session.replaceClip(named, name: "Rename", continuesGesture: false)
        var again = named
        again.name = "second"
        r.session.replaceClip(again, name: "Rename Again", continuesGesture: false)
        r.session.undo()
        let depth = r.session.undoStepDepth
        #expect(r.session.redoName == "Rename Again")

        var c = named
        c.name = "drag 1"
        r.session.replaceClip(c, name: "Item Range", continuesGesture: false)
        #expect(r.session.undoStepDepth == depth + 1)
        #expect(!r.session.canRedo)
        c.name = "drag 2"
        r.session.replaceClip(c, name: "Item Range", continuesGesture: true)
        r.session.replaceClip(named, name: "Item Range", continuesGesture: true)      // the cancel
        #expect(r.session.undoStepDepth == depth)
        #expect(r.session.undoName == "Rename")
        #expect(r.session.redoName == "Rename Again")
        #expect(r.timeline.tracks[0].clips[0].name == "first")
        r.session.redo()
        #expect(r.timeline.tracks[0].clips[0].name == "second")

        // A drag that ends somewhere else is a step, and Redo is gone for good.
        r.session.undo()
        c.name = "drag 3"
        r.session.replaceClip(c, name: "Item Range", continuesGesture: false)
        r.session.replaceClip(named, name: "Item Range", continuesGesture: false)     // a new gesture back to the same clip
        #expect(r.session.undoStepDepth == depth + 2)
        #expect(!r.session.canRedo)
    }

    // MARK: Open / save

    @Test func saveAsThenOpenRoundTrips() async throws {
        let r = try Rig()
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        let url = r.dir.appendingPathComponent("Edit.sqproj")
        try await r.session.saveAs(to: url)
        #expect(r.session.fileURL == url)
        let other = EditorSession(engine: StubProgramEngine(), autosaveStore: r.store)
        try await other.open(url: url)
        #expect(other.project.timelines == r.session.project.timelines)
        #expect(!other.isDirty)
        #expect(other.fileURL == url)
        #expect(other.engine is StubProgramEngine)
    }

    @Test func saveACopyLeavesTheOpenDocumentAlone() async throws {
        let r = try Rig()
        let own = r.dir.appendingPathComponent("Own.sqproj")
        try await r.session.saveAs(to: own)
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        let depth = r.session.undoStepDepth
        let copy = r.dir.appendingPathComponent("Copy.sqproj")
        try await r.session.saveCopy(to: copy)
        #expect(r.session.fileURL == own && r.session.isDirty && r.session.undoStepDepth == depth && r.session.canUndo)
        let other = EditorSession(engine: StubProgramEngine(), autosaveStore: r.store)
        try await other.open(url: copy)
        #expect(other.project.timelines == r.session.project.timelines)
        #expect(other.project.id != r.session.project.id)
        // The original file on disk still holds the state of the last save, not the edit.
        let original = EditorSession(engine: StubProgramEngine(), autosaveStore: r.store)
        try await original.open(url: own)
        #expect(original.project.timelines != r.session.project.timelines)
    }

    @Test func saveACopyOfAnUntitledProjectStaysUntitled() async throws {
        let r = try Rig()
        try await r.session.saveCopy(to: r.dir.appendingPathComponent("C.sqproj"))
        #expect(r.session.fileURL == nil)
        await #expect(throws: EditorSession.SaveError.noFileURL) { try await r.session.save() }
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
        let url = tempDir().appendingPathComponent("x.sqproj")
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

    @Test func recoveryScanFindsCrashedSessionAndRecoversTheUnsavedProject() async throws {
        let r = try Rig()
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        _ = await r.session.tickAutosave()
        let scanner = RecoveryScanner(store: r.store, isProcessAlive: { _ in false })
        let found = EditorSession.recoveryCandidates(scanner: scanner)
        #expect(found.count == 1)
        let recovered = EditorSession(engine: StubProgramEngine(), autosaveStore: r.store)
        try await recovered.recover(found[0], scanner: scanner)
        #expect(recovered.project.name == "P")
        #expect(recovered.project.id == r.session.project.id)
        #expect(recovered.fileURL == nil)
        #expect(recovered.isDirty)
        #expect(recovered.project.timelines == r.session.project.timelines)
        #expect(EditorSession.recoveryCandidates(scanner: scanner).isEmpty)
    }

    /// Crash of a saved project: the next launch offers the autosave, recovering carries on as that project (same file),
    /// Save writes it back there and it reopens equal; once handled, nothing is offered again.
    @Test func crashRecoverSaveReopenEndToEnd() async throws {
        let r = try Rig()
        let own = r.dir.appendingPathComponent("Own.sqproj")
        try await r.session.saveAs(to: own)
        r.clock.now = r.clock.now.addingTimeInterval(1000)
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        #expect(await r.session.tickAutosave())
        // The process dies here: no close, the session marker stays. A new launch scans.
        let scanner = RecoveryScanner(store: r.store, isProcessAlive: { _ in false })
        let found = EditorSession.recoveryCandidates(scanner: scanner)
        #expect(found.count == 1)
        let next = EditorSession(engine: StubProgramEngine(), autosaveStore: r.store)
        try await next.recover(found[0], scanner: scanner)
        #expect(next.fileURL?.resolvingSymlinksInPath() == own.resolvingSymlinksInPath() && next.isDirty)
        #expect(next.project.timelines == r.session.project.timelines)
        #expect(EditorSession.recoveryCandidates(scanner: scanner).isEmpty)
        // Until Save, the file is untouched by the recovery.
        let before = EditorSession(engine: StubProgramEngine(), autosaveStore: r.store)
        try await before.open(url: own)
        #expect(before.project.timelines != r.session.project.timelines)
        try await next.save()
        #expect(!next.isDirty)
        let reopened = EditorSession(engine: StubProgramEngine(), autosaveStore: r.store)
        try await reopened.open(url: own)
        #expect(reopened.project.timelines == r.session.project.timelines)
    }

    @Test func declinedRecoveryIsNotOfferedAgain() async throws {
        let r = try Rig()
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        _ = await r.session.tickAutosave()
        let scanner = RecoveryScanner(store: r.store, isProcessAlive: { _ in false })
        let found = EditorSession.recoveryCandidates(scanner: scanner)
        #expect(found.count == 1)
        scanner.dismiss(found[0])
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
        for _ in 0..<SQTiming.polls(100) where session.project.media.first?.info?.needsColorDetection == true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.project.media.first?.info?.detectedColorSpace == .sLog3SGamut3Cine)
        #expect(session.project.media.first?.info?.embeddedLUTName == "Look")
        #expect(!session.isDirty)
        #expect(!session.canUndo)
    }
}

@MainActor @Suite struct RelinkEngineTests {
    // Review finding 4: relinking a media that was online to another file left the engine on the old file.
    @Test func relinkTellsTheEngineWhichMediaMoved() throws {
        var p = EditorSession.makeUntitled()
        let a = MediaRef(name: "A.mov", path: "/orig/A.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1))
        let b = MediaRef(name: "B.mov", path: "/orig/B.mov", fingerprint: MediaFingerprint(size: 2), duration: Time(2, 1))
        p.add(a); p.add(b)
        let engine = StubProgramEngine()
        let session = EditorSession(project: p, engine: engine, autosaveStore: AutosaveStore(base: tempDir()))
        #expect(engine.changedMedia.isEmpty)
        session.relinkMedia([a.id: "/elsewhere/A.mov"])
        #expect(engine.changedMedia == [[a.id]])
        session.undo()                                              // the old file again: moved back
        #expect(engine.changedMedia == [[a.id], [a.id]])
    }
}

/// The playhead keeps its picture when a ripple closes material before it; undo puts it back, redo moves it again.
/// Rig: V1 a [0,2) b [2,4), 30 fps.
@MainActor @Suite struct PlayheadFollowsRippleTests {
    @Test func rippleDeleteBeforeThePlayheadMovesItWithThePicture() throws {
        let r = try Rig()
        r.session.select(clips: [r.a.id])
        r.session.seek(to: s(3))                          // 1 s into b
        r.session.deleteSelection(ripple: true)
        #expect(r.timeline.tracks[0].clips.map(\.start) == [s(0)])
        #expect(r.session.playhead == s(1))               // still 1 s into b
        #expect(r.engine.position == s(1))
        r.session.undo()
        #expect(r.session.playhead == s(3))
        #expect(r.engine.position == s(3))
        r.session.redo()
        #expect(r.session.playhead == s(1))
    }

    @Test func rippleDeleteOfTheClipUnderThePlayheadLandsOnTheEditPoint() throws {
        let r = try Rig()
        r.session.select(clips: [r.b.id])
        r.session.seek(to: s(3))
        r.session.deleteSelection(ripple: true)
        #expect(r.session.playhead == s(2))
        r.session.undo()
        #expect(r.session.playhead == s(3))
    }

    @Test func rippleDeleteAfterThePlayheadLeavesIt() throws {
        let r = try Rig()
        r.session.select(clips: [r.b.id])
        r.session.seek(to: s(1))
        r.session.deleteSelection(ripple: true)
        #expect(r.session.playhead == s(1))
        r.session.seek(to: s(3))
        r.session.undo()                                  // nothing was moved, so undo has no playhead to put back
        #expect(r.session.playhead == s(3))
    }

    @Test func plainDeleteLeavesThePlayhead() throws {
        let r = try Rig()
        r.session.select(clips: [r.a.id])
        r.session.seek(to: s(3))
        r.session.deleteSelection(ripple: false)
        #expect(r.session.playhead == s(3))
    }

    @Test func closeGapBeforeThePlayheadMovesIt() throws {
        let r = try Rig()
        r.session.select(clips: [r.a.id])
        r.session.deleteSelection(ripple: false)          // gap [0,2)
        r.session.seek(to: s(3))
        r.session.closeGap(GapSelection(track: r.timeline.tracks[0].id, range: TimeRange(start: .zero, end: s(2))))
        #expect(r.timeline.tracks[0].clips.map(\.start) == [s(0)])
        #expect(r.session.playhead == s(1))
        r.session.undo()
        #expect(r.session.playhead == s(3))
        r.session.redo()
        #expect(r.session.playhead == s(1))
    }

    @Test func closeGapUnderThePlayheadLandsOnTheGapStart() throws {
        let r = try Rig()
        r.session.select(clips: [r.a.id])
        r.session.deleteSelection(ripple: false)          // gap [0,2)
        r.session.seek(to: s(1))
        r.session.closeGap(GapSelection(track: r.timeline.tracks[0].id, range: TimeRange(start: .zero, end: s(2))))
        #expect(r.session.playhead == .zero)
        r.session.undo()
        #expect(r.session.playhead == s(1))
    }

    @Test func closeGapAtPlayheadLandsOnTheGapStart() throws {
        let r = try Rig()
        r.session.select(clips: [r.a.id])
        r.session.deleteSelection(ripple: false)          // gap [0,2)
        r.session.seek(to: s(1))
        #expect(r.session.closeGapAtPlayhead())
        #expect(r.timeline.tracks[0].clips.map(\.start) == [s(0)])
        #expect(r.session.playhead == .zero)
        r.session.undo()
        #expect(r.session.playhead == s(1))
        r.session.redo()
        #expect(r.session.playhead == .zero)
    }

    @Test func extractBeforeThePlayheadMovesIt() throws {
        let r = try Rig()
        r.session.seek(to: .zero); r.session.markIn()
        r.session.seek(to: s(1)); r.session.markOut()
        let cut = r.timeline.inOut!.duration
        r.session.seek(to: s(3))
        r.session.extractRange()
        #expect(r.session.playhead == s(3) - cut)
        r.session.undo()
        #expect(r.session.playhead == s(3))
    }

    @Test func committedGestureWithARippleDeleteMovesIt() throws {
        let r = try Rig()
        r.session.seek(to: s(3))
        var out = r.timeline
        try out.rippleDelete([r.a.id])
        r.session.commit(TimelineCommit(timeline: out, edits: [.rippleDelete([r.a.id])], undoName: "Ripple Delete", selection: []))
        #expect(r.session.playhead == s(1))
        r.session.undo()
        #expect(r.session.playhead == s(3))
    }

    @Test func committedGestureWithACloseGapMovesIt() throws {
        let r = try Rig()
        r.session.select(clips: [r.a.id])
        r.session.deleteSelection(ripple: false)
        r.session.seek(to: s(3))
        let track = r.timeline.tracks[0].id
        r.session.commit(TimelineCommit(timeline: r.timeline, edits: [.closeGap(track, at: s(1))], undoName: "Ripple Delete", selection: []))
        #expect(r.session.playhead == s(1))
    }

    @Test func rippleTrimOfAnEarlierTailMovesIt() throws {
        let r = try Rig()
        r.session.seek(to: s(3))
        r.session.trimEdges(EdgeSelection(edges: [EdgeRef(clip: r.a.id, edge: .tail)], ripple: true), frames: -15)
        #expect(r.timeline.tracks[0].clips.map(\.start) == [s(0), Time(3, 2)])
        #expect(r.session.playhead == Time(5, 2))
        r.session.undo()
        #expect(r.session.playhead == s(3))
    }

    @Test func plainTrimLeavesThePlayhead() throws {
        let r = try Rig()
        r.session.seek(to: s(3))
        r.session.trimEdges(EdgeSelection(edges: [EdgeRef(clip: r.a.id, edge: .tail)]), frames: -15)
        #expect(r.session.playhead == s(3))
    }

    @Test func undoOfRippleTrimToPlayheadRestoresThePlayhead() throws {
        let r = try Rig()
        r.session.seek(to: s(3))
        r.session.rippleTrimToPlayhead(.head)
        #expect(r.session.playhead == s(2))
        r.session.undo()
        #expect(r.session.playhead == s(3))
        r.session.redo()
        #expect(r.session.playhead == s(2))
    }

    /// A new edit after the undo replaces the redo step: its playhead record must not fire for the new step.
    @Test func aNewEditAfterUndoForgetsTheOldRedoPlayhead() throws {
        let r = try Rig()
        r.session.select(clips: [r.a.id])
        r.session.seek(to: s(3))
        r.session.deleteSelection(ripple: true)
        r.session.undo()
        r.session.addTrack(.video)
        r.session.undo()
        #expect(r.session.playhead == s(3))
        r.session.redo()
        #expect(r.session.playhead == s(3))
    }

    /// Undo is project-wide: a ripple step of sequence A undone while B is open must not move B's playhead.
    @Test func undoInAnotherSequenceLeavesItsPlayhead() throws {
        let (p0, t, a, _) = try makeProject()
        var p = p0
        var other = Timeline(name: "B", frameDuration: fd, tracks: [Track(kind: .video)])
        try other.tracks[0].overwrite(clip(0, 2))
        p.timelines.append(other)
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        session.select(clips: [a.id])
        session.seek(to: s(3))
        session.deleteSelection(ripple: true)
        #expect(session.playhead == s(1))
        session.setActiveTimeline(other.id)
        session.seek(to: Time(1, 2))
        session.undo()
        #expect(session.activeTimelineID == other.id)
        #expect(session.playhead == Time(1, 2))
        session.redo()
        #expect(session.playhead == Time(1, 2))
        session.setActiveTimeline(t.id)
        session.seek(to: s(1))
        session.undo()                                    // back in A the record applies again
        #expect(session.playhead == s(3))
    }

    /// With the color source view open the monitor runs on file time: the sequence playhead still follows in
    /// sequence time (Rig-like: V1 other [0,2), graded [2,6) showing source 10-14 s of a 30 s file).
    @Test func sequencePlayheadFollowsWhileTheMonitorShowsASourceFile() throws {
        var v1 = Track(kind: .video)
        let first = Clip(name: "other", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero,
                         mediaDuration: s(5))
        let graded = Clip(name: "graded", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(4)), start: s(2),
                          mediaDuration: s(30))
        try v1.overwrite(first); try v1.overwrite(graded)
        let session = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 25), tracks: [v1])]),
                                    engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        session.seek(to: s(3))
        session.colorSoloClip = graded.id
        #expect(session.colorSourceView != nil)
        session.select(clips: [first.id])
        session.deleteSelection(ripple: true)
        #expect(session.playhead == s(1))                 // sequence time, not file time
        session.undo()
        #expect(session.playhead == s(3))
        session.redo()
        #expect(session.playhead == s(1))
    }

    /// Folded steps (Type tool: add + type) keep the playhead move of the steps they swallowed.
    @Test func foldedStepKeepsThePlayheadRecord() throws {
        let r = try Rig()
        let depth = r.session.undoDepth
        r.session.select(clips: [r.a.id])
        r.session.seek(to: s(3))
        r.session.deleteSelection(ripple: true)           // 3 -> 1
        r.session.addTrack(.video)
        r.session.foldUndo(fromDepth: depth, name: "Folded")
        r.session.undo()
        #expect(r.timeline.tracks[0].clips.count == 2)
        #expect(r.session.playhead == s(3))
        r.session.redo()
        #expect(r.session.playhead == s(1))
    }

    @Test func refusedRippleDeleteLeavesThePlayhead() throws {
        let r = try Rig()
        r.session.seek(to: s(3))
        r.session.commit(TimelineCommit(timeline: r.timeline, edits: [.rippleDelete([UUID()])], undoName: "Ripple Delete", selection: []))
        #expect(r.session.playhead == s(3))
        #expect(!r.session.canUndo)
    }
}

@MainActor @Suite struct RecoverySnapshotTests {
    @Test func recoverySnapshotFollowsEditsWithinSecondsAndReplacesItself() async throws {
        let r = try Rig()
        let state = RecoverySnapshotState()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(await r.session.tickRecovery(state, now: t0) == false)           // clean
        try r.session.performTimeline("Delete") { try $0.lift([r.a.id]) }
        #expect(await r.session.tickRecovery(state, now: t0) == true)            // first edit: at once
        #expect(await r.session.tickRecovery(state, now: t0 + 6) == false)       // unchanged: no rewrite
        try r.session.performTimeline("Delete") { try $0.lift([r.b.id]) }
        #expect(await r.session.tickRecovery(state, now: t0 + 2) == false)       // inside the 5 s gap
        #expect(await r.session.tickRecovery(state, now: t0 + 6) == true)
        let versions = r.store.versions(for: r.session.project.id)
        #expect(versions.count == 1)                                             // replaced its own previous one
        let saved = try r.store.read(versions[0])
        #expect(saved.timelines == r.session.project.timelines)
    }
}
