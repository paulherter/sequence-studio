import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession() -> (EditorSession, MediaRef) {
    let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                           nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
    let a = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")
    let m = MediaRef(name: "A", path: "/nonexistent/A.mov", fingerprint: MediaFingerprint(size: 1),
                     duration: s(10), info: MediaInfo(duration: s(10), video: v, audio: a))
    let session = EditorSession(engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
        .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
    session.perform("Import") { $0.add(m) }
    return (session, m)
}

@MainActor @Suite struct PlaceSequenceSessionTests {
    /// Sequence "B" with 10 s of media (V + A); the active sequence is a new empty "A".
    private func twoSequences() -> (EditorSession, a: Timeline.ID, b: Timeline.ID) {
        let (session, m) = makeSession()
        let b = session.activeTimelineID!
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))
        let a = session.addSequence(name: "A", format: session.activeTimeline!.format)
        return (session, a, b)
    }

    @Test func dropSequenceCreatesNestedVideoAndAudioClips() {
        let (session, a, b) = twoSequences()
        let dur = session.project.timeline(b)!.duration
        #expect(session.placeSequences([b], at: s(1), mode: .overwrite))
        let tl = session.project.timeline(a)!
        let v = tl.tracks.first { $0.kind == .video }!.clips, au = tl.tracks.first { $0.kind == .audio }!.clips
        #expect(v.count == 1 && au.count == 1)
        #expect(v[0].sequence == b && au[0].sequence == b && v[0].link == au[0].link && v[0].link != nil)
        #expect(v[0].source.duration == dur && v[0].start == s(1))
    }

    @Test func asClipsSettingPlacesTheSequencesOwnClipsInOneUndoStep() {
        let (session, a, b) = twoSequences()
        session.placeSequencesAsClips = true
        let before = session.project.timeline(a)!
        #expect(session.placeSequences([b], at: s(1), mode: .overwrite))
        let tl = session.project.timeline(a)!
        let v = tl.tracks.first { $0.kind == .video }!.clips, au = tl.tracks.first { $0.kind == .audio }!.clips
        #expect(v.count == 1 && au.count == 1 && v[0].sequence == nil && au[0].sequence == nil)
        #expect(v[0].media == session.project.timeline(b)!.tracks.first { $0.kind == .video }!.clips[0].media && v[0].start == s(1))
        session.undo()
        #expect(session.project.timeline(a)! == before)
    }

    @Test func insertAtPlayheadAndUndo() {
        let (session, a, b) = twoSequences()
        session.seek(to: s(2))
        let before = session.project.timeline(a)!
        #expect(session.placeSequences([b], mode: .insert))
        #expect(session.project.timeline(a)!.duration > before.duration)
        session.undo()
        #expect(session.project.timeline(a)! == before)
    }

    @Test func nestedSequenceDropsIntoAnother() {
        let (session, a, b) = twoSequences()
        let c = session.addSequence(name: "C", format: session.activeTimeline!.format)
        #expect(session.placeSequences([a], mode: .overwrite) == false)           // A is empty: refused
        session.setActiveTimeline(a)
        #expect(session.placeSequences([b], mode: .overwrite))                     // B into A
        session.setActiveTimeline(c)
        #expect(session.placeSequences([a], mode: .overwrite))                     // A (containing B) into C
        #expect(session.project.reachableSequences(from: c) == [a, b])
    }

    @Test func selfDropIsRefusedWithMessage() {
        let (session, _, b) = twoSequences()
        session.setActiveTimeline(b)
        let before = session.project
        #expect(session.sequenceNestingRefusal([b]) != nil)
        #expect(!session.placeSequences([b], mode: .overwrite))
        #expect(session.lastError?.contains("cannot contain itself") == true)
        #expect(session.project == before)
    }

    @Test func transitiveCycleIsRefused() {
        let (session, a, b) = twoSequences()
        #expect(session.placeSequences([b], mode: .overwrite))                     // B in A
        session.setActiveTimeline(b)
        #expect(session.sequenceNestingRefusal([a]) != nil)                        // A into B would loop
        let before = session.project
        #expect(!session.placeSequences([a], mode: .overwrite))
        #expect(session.project == before)
    }

    @Test func dropOnGhostTrackCreatesTrackInOneUndoStep() {
        let (session, a, b) = twoSequences()
        let n = session.project.timeline(a)!.tracks.filter { $0.kind == .video }.count
        let before = session.project.timeline(a)!
        #expect(session.placeSequences([b], mode: .overwrite, newTrack: .video))
        #expect(session.project.timeline(a)!.tracks.filter { $0.kind == .video }.count == n + 1)
        session.undo()
        #expect(session.project.timeline(a)! == before)
    }
}
