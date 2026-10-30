import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct SplitEditSessionTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }
    private let sfxMedia = UUID()

    private func makeSession() -> EditorSession {
        func c(_ start: Int64, _ kind: TrackKind) -> Clip {
            Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: Time(5, 1), duration: Time(10, 1)), start: Time(start, 1),
                 mediaDuration: Time(60, 1))
        }
        var v = Track(kind: .video, isTargeted: true), a = Track(kind: .audio, isTargeted: true)
        try! v.overwrite(c(0, .video)); try! v.overwrite(c(10, .video))
        try! a.overwrite(c(0, .audio)); try! a.overwrite(c(10, .audio))
        let tl = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v, a])
        var p = Project(name: "P", timelines: [tl])
        p.add(MediaRef(id: sfxMedia, name: "Whoosh", path: "/tmp/whoosh.wav", fingerprint: MediaFingerprint(size: 1, modified: Date()),
                       duration: Time(2, 1)))
        return EditorSession(project: p, engine: StubProgramEngine())
    }

    @Test func splitEditMovesOnlyTheAudioCutInOneUndoStep() {
        let ses = makeSession()
        let before = ses.activeTimeline!
        ses.seek(to: s(8))
        #expect(ses.splitEditToPlayhead(.audio))
        #expect(ses.undoName == "Split Edit Audio")
        let t = ses.activeTimeline!
        #expect(t.tracks[0].clips.map(\.start) == [s(0), s(10)])
        #expect(t.tracks[1].clips.map(\.start) == [s(0), s(8)])
        ses.undo()
        #expect(ses.activeTimeline! == before)
    }

    @Test func playheadOnTheCutDoesNothing() {
        let ses = makeSession()
        ses.seek(to: s(10))
        #expect(!ses.splitEditToPlayhead(.video))
    }

    @Test func whooshLandsCentredOnTheSelectedCutOnAFreeTrack() {
        let ses = makeSession()
        let v0 = ses.activeTimeline!.tracks[0].clips[0]
        ses.select(clips: [v0.id])
        let cuts = ses.selectedCuts(edges: [])
        #expect(cuts == [s(10)])
        #expect(ses.addWhoosh(media: sfxMedia, atCuts: cuts))
        #expect(ses.undoName == "Whoosh at Cuts")
        let t = ses.activeTimeline!
        #expect(t.tracks.count == 3)
        #expect(t.tracks[2].clips[0].start == s(9))
        #expect(t.tracks[2].clips[0].audioTag == .sfx)
        ses.undo()
        #expect(ses.activeTimeline!.tracks.count == 2)
    }

    @Test func whooshWithoutCutsRefuses() {
        let ses = makeSession()
        #expect(!ses.addWhoosh(media: sfxMedia, atCuts: []))
    }
}
