import Foundation
import Testing
@testable import SQCore

@Suite struct MuteDetachTests {
    private func setup() -> (Timeline, v: Clip, a: Clip, plain: Clip) {
        let l = UUID()
        func c(_ s: Int64, _ k: TrackKind, link: UUID? = nil) -> Clip {
            Clip(name: "c", media: UUID(), kind: k, source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(s, 1), link: link)
        }
        let v = c(0, .video, link: l), a = c(0, .audio, link: l), plain = c(5, .audio)
        var vt = Track(kind: .video), at = Track(kind: .audio), pt = Track(kind: .audio)
        try! vt.overwrite(v); try! at.overwrite(a); try! pt.overwrite(plain)
        return (Timeline(name: "T", frameDuration: Time(1, 30), tracks: [vt, at, pt]), v, a, plain)
    }

    @Test func muteTogglesAudioTrackOfClipAndPartner() {
        var (t, v, _, _) = setup()
        #expect(t.toggleMute(forClips: [v.id]) == true)
        #expect(t.tracks[1].isMuted && !t.tracks[2].isMuted)
        #expect(t.toggleMute(forClips: [v.id]) == false)
        #expect(!t.tracks[1].isMuted)
        var vt = Track(kind: .video)
        try! vt.overwrite(Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero))
        var onlyVideo = Timeline(name: "V", frameDuration: Time(1, 30), tracks: [vt])
        #expect(onlyVideo.toggleMute(forClips: [vt.clips[0].id]) == nil)
    }

    @Test func detachAudioUnlinksAndKeepsPosition() throws {
        var (t, v, a, plain) = setup()
        let out = try t.detachAudio(of: [v.id])
        #expect(out == [a.id])
        #expect(t.tracks[0].clips[0].link == nil)
        #expect(t.tracks[1].clips[0].link == nil)
        #expect(t.tracks[1].clips[0].start == a.start)
        #expect(try t.detachAudio(of: [v.id]).isEmpty)
        #expect(try t.detachAudio(of: [plain.id]).isEmpty)
    }

    @Test func detachAudioRefusesLockedTrack() {
        var (t, v, _, _) = setup()
        t.tracks[1].isLocked = true
        #expect(throws: (any Error).self) { try t.detachAudio(of: [v.id]) }
        #expect(t.tracks[0].clips[0].link != nil)
    }
}
