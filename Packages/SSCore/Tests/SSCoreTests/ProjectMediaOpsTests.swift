import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct ProjectMediaOpsTests {
    private func media() -> MediaRef {
        let v = VideoTrackInfo(width: 1080, height: 1920, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        let a = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "aac")
        return MediaRef(name: "clip.mov", path: "/x/clip.mov", fingerprint: MediaFingerprint(size: 1),
                        duration: s(8), info: MediaInfo(duration: s(8), video: v, audio: a))
    }

    @Test func sequenceFromClipUsesClipFormatAndHoldsClip() throws {
        var p = Project(name: "p")
        let m = media()
        p.add(m)
        let t = try #require(p.sequence(fromMedia: m.id))
        #expect(t.name == "clip")
        #expect(t.format.width == 1080 && t.format.height == 1920 && t.format.frameDuration == Time(1, 30))
        #expect(t.duration == s(8))
        let clips = t.tracks.flatMap(\.clips)
        #expect(clips.count == 2 && clips.allSatisfy { $0.media == m.id && $0.start == .zero })
        #expect(t.formatLocked)
    }

    @Test func replaceKeepsIdentity() {
        var p = Project(name: "p")
        let m = media()
        p.add(m)
        var other = media()
        other.path = "/y/new.mov"; other.duration = s(9)
        let ok = p.replaceMedia(m.id, with: other)
        #expect(ok)
        let r = p.media(m.id)!
        #expect(r.id == m.id && r.name == "clip.mov" && r.path == "/y/new.mov" && r.duration == s(9))
        let missing = p.replaceMedia(UUID(), with: other)
        #expect(!missing)
    }
}
