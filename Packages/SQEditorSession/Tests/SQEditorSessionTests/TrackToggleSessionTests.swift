import Foundation
import Testing
import SQCore
@testable import SQEditorSession

// AUDIT A7: a toggle on several tracks is one undo step; a single toggle keeps its state-specific name.

@MainActor @Suite struct TrackToggleSessionTests {
    private func rig() -> (EditorSession, [Track.ID]) {
        let tracks = [Track(kind: .video), Track(kind: .video), Track(kind: .audio)]
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: tracks)
        return (EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine()), tracks.map(\.id))
    }

    @Test func singleToggleFlipsOneTrackWithItsName() {
        let (s, ids) = rig()
        s.toggleTracks(of: ids[0], .lock, allOfKind: false)
        #expect(s.activeTimeline!.tracks.map(\.isLocked) == [true, false, false])
        #expect(s.undoName == "Lock Track")
    }

    @Test func allOfKindIsOneStepThatUndoesTogether() {
        let (s, ids) = rig()
        s.toggleTracks(of: ids[0], .mute, allOfKind: true)
        #expect(s.activeTimeline!.tracks.map(\.isMuted) == [true, true, false])
        #expect(s.undoName == "Mute Tracks")
        s.undo()
        #expect(s.activeTimeline!.tracks.map(\.isMuted) == [false, false, false])
        #expect(s.undoName == nil)
    }

    @Test func allOfKindTakesTheNewValueOfTheClickedTrack() {
        let (s, ids) = rig()
        s.toggleTracks(of: ids[1], .solo, allOfKind: false)       // V2 on
        s.toggleTracks(of: ids[0], .solo, allOfKind: true)        // V1 off -> on; V2 already on stays on
        #expect(s.activeTimeline!.tracks.map(\.isSolo) == [true, true, false])
        s.toggleTracks(of: ids[0], .solo, allOfKind: true)        // V1 on -> off for all video tracks
        #expect(s.activeTimeline!.tracks.map(\.isSolo) == [false, false, false])
        #expect(s.undoName == "Unsolo Tracks")
    }
}
