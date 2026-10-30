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

@MainActor private func ids(_ session: EditorSession, _ k: TrackKind) -> [Track.ID] {
    session.activeTimeline!.tracks.filter { $0.kind == k }.map(\.id)
}

/// MON-30: Source Insert / Overwrite follow the source patch; track targeting does not.
@MainActor @Suite struct SourcePatchSessionTests {
    @Test func bRollToV2WithoutItsAudio() {
        let (session, m) = makeSession()
        let v = ids(session, .video)
        session.patchSource(.video, to: v[1])
        session.toggleSourcePatch(.audio)
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))
        let tl = session.activeTimeline!
        #expect(tl.track(v[1])?.clips.count == 1)
        #expect(tl.tracks.filter { $0.kind == .audio }.allSatisfy { $0.clips.isEmpty })
    }

    @Test func untargetedTracksStillReceiveThePatchedEdit() {
        let (session, m) = makeSession()
        let v = ids(session, .video), a = ids(session, .audio)
        session.toggleTarget(v[0], shift: false, option: false); session.toggleTarget(a[0], shift: false, option: false)
        #expect(session.activeTimeline!.tracks.allSatisfy { !$0.isTargeted })
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))
        #expect(session.activeTimeline!.track(v[0])?.clips.count == 1)
        #expect(session.activeTimeline!.track(a[0])?.clips.count == 1)
    }

    @Test func patchIsOneUndoStepAndSavedWithItsSequence() throws {
        let (session, _) = makeSession()
        let v = ids(session, .video)
        session.patchSource(.video, to: v[2])
        #expect(session.activeTimeline!.sourcePatch.video.track == v[2])
        session.undo()
        #expect(session.sourcePatch == SourcePatch())
        session.redo()
        #expect(session.sourcePatch.video.track == v[2])
        // Stored on the sequence itself, so it is saved with the project (file round trip: ProjectFileV88Tests).
        #expect(session.project.timelines[0].sourcePatch.video.track == v[2])
        #expect(session.activeTimeline!.patchedTrack(session.sourcePatch, kind: .video) == v[2])
        session.patchSource(.video, to: ids(session, .audio)[0])          // wrong kind: ignored
        #expect(session.activeTimeline!.patchedTrack(session.sourcePatch, kind: .video) == v[2])
    }

    @Test func everythingDisconnectedSaysSo() {
        let (session, m) = makeSession()
        session.toggleSourcePatch(.video); session.toggleSourcePatch(.audio)
        #expect(!session.sourceEdit(media: m.id, mode: .overwrite))
        #expect(session.lastError?.contains("patched") == true)
        #expect(session.activeTimeline!.tracks.allSatisfy { $0.clips.isEmpty })
    }

    @Test func placeOnTopHonoursADisconnectedVideoPatch() {
        let (session, m) = makeSession()
        session.toggleSourcePatch(.video)
        #expect(!session.sourceEdit(media: m.id, mode: .overwrite, placeOnTop: true))
        #expect(!session.placeMedia([m.id], mode: .overwrite, placeOnTop: true, patched: true))
        session.toggleSourcePatch(.video)
        #expect(session.sourceEdit(media: m.id, mode: .overwrite, placeOnTop: true))
    }

    @Test func projectPanelKeysUseThePatchDropsDoNot() {
        let (session, m) = makeSession()
        let v = ids(session, .video), a = ids(session, .audio)
        session.patchSource(.audio, to: a[2])
        #expect(session.placeMedia([m.id], at: .zero, mode: .overwrite, patched: true))
        #expect(session.activeTimeline!.track(a[2])?.clips.count == 1)
        #expect(session.activeTimeline!.track(v[0])?.clips.count == 1)
        // A drop on V2 keeps the drop rule (mirrored audio on A2).
        #expect(session.placeMedia([m.id], at: s(20), videoTrack: v[1], mode: .overwrite, patched: true))
        #expect(session.activeTimeline!.track(v[1])?.clips.count == 1)
        #expect(session.activeTimeline!.track(a[1])?.clips.count == 1)
    }

    @Test func soloAndPatchBothAreUndoSteps() {
        let (session, m) = makeSession()
        let v = ids(session, .video)
        session.soloSourcePatch(.video)
        #expect(session.sourcePatch.video.isConnected && !session.sourcePatch.audio.isConnected)
        session.undo()
        #expect(session.sourcePatch == SourcePatch())
        session.patchSourceBoth(.video, to: v[1])
        #expect(session.sourcePatch.video.track == v[1])
        #expect(session.sourcePatch.audio.track == ids(session, .audio)[1])
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))
    }
}
