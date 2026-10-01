import Foundation
import Testing
@testable import SQCore

@Suite struct DropTargetsTests {
    private func timeline(video: Int = 3, audio: Int = 2) -> Timeline {
        Timeline(name: "t", format: SequenceFormat(frameDuration: Time(1, 30)),
                 tracks: Timeline.defaultTracks(video: video, audio: audio))
    }
    private func v(_ t: Timeline, _ n: Int) -> Track.ID { t.tracks.filter { $0.kind == .video }[n].id }
    private func a(_ t: Timeline, _ n: Int) -> Track.ID { t.tracks.filter { $0.kind == .audio }[n].id }

    @Test func audioMirrorsTheVideoTrack() {
        let t = timeline()
        let r = t.dropTargets(pointer: v(t, 1), hasVideo: true, hasAudio: true)
        #expect(r.video == v(t, 1) && r.audio == a(t, 1) && r.newAudioOrdinal == nil)
    }

    @Test func missingMirroredAudioTrackIsReportedAndCreated() {
        var t = timeline()
        let r = t.dropTargets(pointer: v(t, 2), hasVideo: true, hasAudio: true)
        #expect(r.audio == nil && r.newAudioOrdinal == 2)
        let id = t.ensureAudioTrack(atOrdinal: 2)
        #expect(t.tracks.filter { $0.kind == .audio }.count == 3)
        #expect(t.ordinal(of: id) == 2)
        #expect(t.dropTargets(pointer: v(t, 2), hasVideo: true, hasAudio: true).audio == id)
    }

    @Test func noPointerUsesTargetedVideoAndItsMirror() {
        let t = timeline()
        let r = t.dropTargets(pointer: nil, hasVideo: true, hasAudio: true)
        #expect(r.video == v(t, 0) && r.audio == a(t, 0))
    }

    @Test func audioOnlyOnAudioTrackStaysThere() {
        let t = timeline()
        #expect(t.dropTargets(pointer: a(t, 1), hasVideo: false, hasAudio: true).audio == a(t, 1))
        #expect(t.dropTargets(pointer: v(t, 1), hasVideo: false, hasAudio: true).audio == a(t, 1))
    }

    @Test func videoOnlyHasNoAudioTarget() {
        let t = timeline()
        let r = t.dropTargets(pointer: v(t, 1), hasVideo: true, hasAudio: false)
        #expect(r.video == v(t, 1) && r.audio == nil && r.newAudioOrdinal == nil)
    }

    @Test func audioOverwriteIsPerTargetTrack() throws {
        var t = timeline()
        let other = Clip(name: "x", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        try t.overwrite([(other, a(t, 0))], at: .zero)
        // Drop on V2: audio lands on A2, A1 is untouched.
        let r = t.dropTargets(pointer: v(t, 1), hasVideo: true, hasAudio: true)
        try t.threePointEdit(source: TimeRange(start: .zero, duration: Time(4, 1)), media: UUID(), targets: [r.video!, r.audio!],
                             at: Time(2, 1), mode: .overwrite)
        #expect(t.track(a(t, 0))!.clips == [other])
        #expect(t.track(a(t, 1))!.clips.count == 1)
    }
}
