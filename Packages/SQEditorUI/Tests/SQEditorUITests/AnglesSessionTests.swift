import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

// F7.16 Angles clip at the session level: create from media and from timeline clips, switch by number key (stopped
// and playing), the menu state, the dialog's choices and the key bindings.
@MainActor @Suite struct AnglesSessionTests {
    private func ref(_ name: String, seconds: Int64 = 10, audio: Bool = true) -> MediaRef {
        let video = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                   nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
        return MediaRef(name: name, path: "/nowhere/\(name).mov", fingerprint: MediaFingerprint(size: 1), duration: Time(seconds, 1),
                        info: MediaInfo(duration: Time(seconds, 1), video: video,
                                        audio: audio ? AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm") : nil))
    }

    private func format() -> SequenceFormat { SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25), audioSampleRate: 48_000) }

    /// Session with three media items and an empty sequence.
    private func make() -> (EditorSession, [MediaRef]) {
        let refs = [ref("Wide"), ref("Close"), ref("Side", audio: false)]
        let t = Timeline(name: "Main", format: format(), tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio), Track(kind: .audio)])
        return (EditorSession(project: Project(name: "P", media: refs, timelines: [t]), engine: StubProgramEngine()), refs)
    }

    /// Creates the Angles sequence from all media and places it at 0; returns the video and audio piece.
    private func placed(_ s: EditorSession, _ refs: [MediaRef]) throws -> (Timeline.ID, Clip, Clip) {
        let seq = try #require(s.createAnglesSequence(media: refs.map(\.id)))
        #expect(s.placeSequences([seq], at: .zero))
        let clips = try #require(s.activeTimeline).tracks.flatMap(\.clips)
        return (seq, try #require(clips.first { $0.kind == .video }), try #require(clips.first { $0.kind == .audio }))
    }

    @Test func mediaBecomeOneAnglesSequenceShiftedByTheirOrigins() throws {
        let (s, refs) = make()
        // Close started recording 2 s after Wide, Side 1 s before it.
        let seq = try #require(s.createAnglesSequence(media: refs.map(\.id), name: "  Concert ",
                                                      origins: [refs[0].id: .zero, refs[1].id: Time(2, 1), refs[2].id: Time(-1, 1)],
                                                      audioAngle: 1))
        let inner = try #require(s.project.timeline(seq))
        #expect(inner.name == "Concert")
        #expect(inner.angleNames == ["Wide", "Close", "Side"])
        #expect(inner.angles?.audioAngle == 1)
        let video = inner.tracks.filter { $0.kind == .video }
        #expect(video.map { $0.clips.first?.start } == [Time(1, 1), Time(3, 1), .zero])
        #expect(inner.format.frameDuration == Time(1, 25))
        #expect(s.history.canUndo)
    }

    @Test func oneMediaItemIsRefused() {
        let (s, refs) = make()
        #expect(s.createAnglesSequence(media: [refs[0].id]) == nil)
        #expect(s.lastError != nil)
        #expect(s.angleCandidates(media: refs.map(\.id)).map(\.hasAudio) == [true, true, false])
    }

    @Test func anAnglesSequenceIsPlacedAsOneClipEvenWhenSequencesArePlacedAsClips() throws {
        let (s, refs) = make()
        s.placeSequencesAsClips = true
        let (seq, v, a) = try placed(s, refs)
        #expect(v.sequence == seq && v.isAnglesClip && a.isAnglesClip)
        #expect(try #require(s.activeTimeline).tracks.flatMap(\.clips).count == 2)
    }

    @Test func flattenTurnsTheAnglesPiecesIntoPlainClipsAndUndoBringsThemBack() throws {
        let (s, refs) = make()
        let (_, v, _) = try placed(s, refs)
        #expect(s.switchAngle(2) == .switched)
        #expect(s.flattenAngles(clip: v.id))
        let flat = try #require(s.activeTimeline).tracks.flatMap(\.clips)
        #expect(!flat.isEmpty && flat.allSatisfy { !$0.isAnglesClip && $0.sequence == nil })
        #expect(flat.first { $0.kind == .video }?.media == refs[1].id)
        s.undo()
        #expect(try #require(s.activeTimeline).tracks.flatMap(\.clips).allSatisfy(\.isAnglesClip))
    }

    @Test func numberKeySwitchesTheSelectedPieceOrThePieceUnderThePlayhead() throws {
        let (s, refs) = make()
        let (_, v, a) = try placed(s, refs)
        s.select(clips: [])
        s.seek(to: Time(1, 1))
        #expect(s.switchAngle(2) == .switched)
        func clip(_ id: Clip.ID) -> Clip? { s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id } }
        #expect(clip(v.id)?.angle?.index == 1)
        #expect(clip(a.id)?.angle?.index == 0)          // the sound stays on its angle
        #expect(s.switchAngle(2) == .unchanged)
        #expect(s.switchAngle(7) == .noSuchAngle(count: 3))
        // Only the sound piece selected: the key chooses the sound's angle.
        s.select(clips: [a.id])
        #expect(s.switchAngle(2) == .switched)
        #expect(clip(a.id)?.angle?.index == 1)
        s.select(clips: [])
        s.seek(to: Time(60, 1))
        #expect(s.switchAngle(1) == .noAnglesClip)
    }

    @Test func numberKeyWhilePlayingCutsAtThePlayheadWithOneUndoStepPerSwitch() throws {
        let (s, refs) = make()
        _ = try placed(s, refs)
        s.seek(to: Time(2, 1))
        s.playPause()
        #expect(s.isPlaying)
        let depth = s.history.undoDepth
        #expect(s.switchAngle(3) == .switched)
        #expect(s.history.undoDepth == depth + 1)
        let video = try #require(s.activeTimeline).tracks.flatMap(\.clips).filter { $0.kind == .video }.sorted { $0.start < $1.start }
        #expect(video.map(\.start) == [.zero, Time(2, 1)])
        #expect(video.map { $0.angle?.index } == [0, 2])
        // Every part has its own linked sound part, so the menu knows Audio Follows Video on the later part too.
        #expect(try #require(s.activeTimeline).tracks.flatMap(\.clips).filter { $0.kind == .audio }.map(\.link) == video.map(\.link))
        #expect(s.angleMenuState(for: video[1].id)?.followsVideo == false)
        #expect(s.switchAngle(3) == .unchanged)
        #expect(s.history.undoDepth == depth + 1)
        s.playPause()
        s.undo()
        #expect(try #require(s.activeTimeline).tracks.flatMap(\.clips).filter { $0.kind == .video }.count == 1)
    }

    @Test func timelineClipsBecomeAnAnglesClipAndTheMenuStateFollows() throws {
        let (s, refs) = make()
        let link1 = UUID(), link2 = UUID()
        func clip(_ r: MediaRef, _ kind: TrackKind, _ start: Time, _ link: UUID) -> Clip {
            Clip(name: r.name, media: r.id, kind: kind, source: TimeRange(start: .zero, duration: Time(4, 1)), start: start, link: link)
        }
        let clips = [clip(refs[0], .video, .zero, link1), clip(refs[1], .video, Time(1, 1), link2),
                     clip(refs[0], .audio, .zero, link1), clip(refs[1], .audio, Time(1, 1), link2)]
        try s.performTimeline("Setup") { t in for (i, c) in clips.enumerated() { try t.tracks[i].overwrite(c) } }
        s.select(clips: Set(clips.map(\.id)))
        #expect(s.angleCandidatesOfSelection.map(\.name) == ["Wide", "Close"])
        // Sync by In point: both angles start together although Close sat 1 s later in the timeline.
        let seq = try #require(s.createAnglesClipFromSelection(name: "", origins: [:], audioFollowsVideo: true))
        let inner = try #require(s.project.timeline(seq))
        #expect(inner.tracks.filter { $0.kind == .video }.map { $0.clips.first?.start } == [.zero, .zero])
        let made = try #require(s.activeTimeline).tracks.flatMap(\.clips)
        #expect(made.count == 2 && made.allSatisfy(\.isAnglesClip))
        #expect(s.selection == Set(made.map(\.id)))
        let v = try #require(made.first { $0.kind == .video }), a = try #require(made.first { $0.kind == .audio })
        let state = try #require(s.angleMenuState(for: v.id))
        #expect(state.names == ["Wide", "Close"] && state.active == 0 && !state.isAudio && state.followsVideo == true)
        #expect(s.setAngle(1, on: v.id))
        #expect(s.angleMenuState(for: a.id)?.active == 1)          // Audio Follows Video
        #expect(s.setAudioFollowsVideo(false, on: v.id))
        #expect(s.setAngle(0, on: v.id))
        #expect(s.angleMenuState(for: a.id)?.active == 1)
        #expect(s.angleMenuState(for: a.id)?.isAudio == true)
    }

    @Test func inPointSyncStartsEveryAngleAtItsInPoint() throws {
        // From media: Wide has In at 4 s, Close none. Without origins both start at 0 of the Angles sequence.
        let (s, refs) = make()
        try s.perform("Marks") { $0.sourceMarks[refs[0].id] = SourceMarks(markIn: Time(4, 1)) }
        let seq = try #require(s.createAnglesSequence(media: [refs[0].id, refs[1].id]))
        let video = try #require(s.project.timeline(seq)).tracks.filter { $0.kind == .video }
        #expect(video.map { $0.clips.first?.start } == [.zero, .zero])
        #expect(video.map { $0.clips.first?.source.start } == [Time(4, 1), .zero])
        // With origins the files' time 0 is placed: Wide (origin 0, In 4) starts 4 s after Close (origin 0, In 0).
        let timed = try #require(s.createAnglesSequence(media: [refs[0].id, refs[1].id], origins: [refs[0].id: .zero, refs[1].id: .zero]))
        #expect(try #require(s.project.timeline(timed)).tracks.filter { $0.kind == .video }.map { $0.clips.first?.start } == [Time(4, 1), .zero])
        // Only Close is placed (Wide's sound did not match): Wide's In point goes to 0 as well.
        let partly = try #require(s.createAnglesSequence(media: [refs[0].id, refs[1].id], origins: [refs[1].id: Time(7, 1)]))
        #expect(try #require(s.project.timeline(partly)).tracks.filter { $0.kind == .video }.map { $0.clips.first?.start } == [.zero, .zero])
    }

    @Test func inPointSyncOfTimelineClipsIgnoresWhereTheSourceRangesStart() throws {
        let (s, refs) = make()
        func clip(_ r: MediaRef, _ src: Int64, _ start: Int64) -> Clip {
            Clip(name: r.name, media: r.id, kind: .video, source: TimeRange(start: Time(src, 1), duration: Time(4, 1)), start: Time(start, 1))
        }
        let clips = [clip(refs[0], 5, 0), clip(refs[1], 0, 2)]
        try s.performTimeline("Setup") { t in for (i, c) in clips.enumerated() { try t.tracks[i].overwrite(c) } }
        // The list is taken once: a later selection change does not change what is built.
        s.select(clips: Set(clips.map(\.id)))
        let captured = s.angleSelection
        s.select(clips: [])
        #expect(s.angleCandidates(clips: captured).map(\.name) == ["Wide", "Close"])
        let seq = try #require(s.createAnglesClip(from: captured, origins: [:]))
        #expect(try #require(s.project.timeline(seq)).tracks.filter { $0.kind == .video }.map { $0.clips.first?.start } == [.zero, .zero])
        #expect(try #require(s.activeTimeline).tracks.flatMap(\.clips).allSatisfy(\.isAnglesClip))
    }

    @Test func aKeyThatChangesNothingDoesNotCutAndALockedFixedSoundDoesNotStopTheSwitch() throws {
        let (s, refs) = make()
        _ = try placed(s, refs)
        let depth = s.history.undoDepth
        func count() -> Int { s.activeTimeline?.tracks.flatMap(\.clips).count ?? 0 }
        s.select(clips: [])
        s.seek(to: Time(2, 1))
        s.playPause()
        #expect(s.switchAngle(1) == .unchanged)                  // the piece already shows angle 1
        #expect(s.switchAngle(9) == .noSuchAngle(count: 3))
        #expect(count() == 2 && s.history.undoDepth == depth)
        // A locked sound track does not stop the live switch while the sound keeps its angle.
        s.playPause()
        try s.performTimeline("Lock") { t in for i in t.tracks.indices where t.tracks[i].kind == .audio { t.tracks[i].isLocked = true } }
        s.seek(to: Time(2, 1))
        s.playPause()
        #expect(s.switchAngle(2) == .switched)
        #expect(count() == 3)
        let later = try #require(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.kind == .video && $0.start == Time(2, 1) })
        #expect(s.angleMenuState(for: later.id)?.followsVideo == false)      // the uncut sound under it
        s.playPause()
    }

    @Test func dialogOffersWhatTheAnglesAllow() {
        let two = [AngleCandidate(name: "A", media: UUID(), hasAudio: false), AngleCandidate(name: "B", media: UUID(), hasAudio: true)]
        #expect(AnglesDialog.syncChoices(angles: two, fromTimeline: false) == [.inPoints, .timecode])
        #expect(AnglesDialog.defaultAudioAngle(two) == 1)
        let sound = two + [AngleCandidate(name: "C", media: nil, hasAudio: true)]
        #expect(AnglesDialog.syncChoices(angles: sound, fromTimeline: true) == [.timelinePositions, .inPoints, .timecode, .audio])
        #expect(AnglesDialog.defaultName(existing: ["Angles 01", "Main"]) == "Angles 02")
    }

    @Test func numberKeysAreBoundInTimelineAndProgramOnly() {
        let map = CommandMap.premiereDefault
        for scope in [CommandScope.timeline, .program] {
            let keys = map.entries.filter { $0.scope == scope }.compactMap { e -> Int? in
                if case .switchAngle(let n) = e.command { return n } else { return nil }
            }
            #expect(keys.sorted() == Array(1...9))
        }
        #expect(!map.entries.contains { e in
            if case .switchAngle = e.command { return e.scope != .timeline && e.scope != .program } else { return false }
        })
        #expect(EditorCommand.switchAngle(4).id == "switchAngle.4")
        #expect(EditorCommand.switchAngle(4).title == "Switch to Angle 4")
    }

    @Test func projectMenuOffersAnglesForSeveralMediaItems() {
        let rows = ProjectPanelMenus.items(.init(media: [UUID(), UUID()], targetCount: 2, allMediaOnline: true, hasNonBinTarget: true),
                                           shortcut: { _ in "" }) { _ in }
        #expect(rows.first { $0.title == "Create Angles Clip…" }?.isEnabled == true)
        let one = ProjectPanelMenus.items(.init(media: [UUID()], targetCount: 1, allMediaOnline: true, hasNonBinTarget: true),
                                          shortcut: { _ in "" }) { _ in }
        #expect(!one.contains { $0.title == "Create Angles Clip…" })
    }
}
