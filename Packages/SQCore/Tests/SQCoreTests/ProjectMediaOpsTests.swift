import Foundation
import Testing
@testable import SQCore

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

    @Test func replaceWithShorterMediaTrimsClipsAndMarks() throws {
        var p = Project(name: "p")
        let m = media()                                   // 8 s
        p.add(m)
        var t = p.sequence(fromMedia: m.id)!
        let id = t.tracks.flatMap(\.clips).first { $0.kind == .video }!.id
        _ = id
        p.timelines.append(t)
        p.sourceMarks[m.id] = SourceMarks(markIn: s(6), markOut: s(8))
        var shorter = media()
        shorter.duration = s(5)
        shorter.info?.duration = s(5)
        p.replaceMedia(m.id, with: shorter)
        t = p.timelines[0]
        let clips = t.tracks.flatMap(\.clips)
        #expect(clips.allSatisfy { $0.mediaDuration == s(5) && $0.source.end == s(5) })
        #expect(p.sourceMarks[m.id]?.markIn == nil && p.sourceMarks[m.id]?.markOut == s(5))   // In past the end dropped, Out clamped
    }

    @Test func replaceDropsClipsStartingPastTheNewEnd() throws {
        var p = Project(name: "p")
        let m = media()
        p.add(m)
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        try tl.tracks[0].overwrite(Clip(name: "c", media: m.id, kind: .video, source: TimeRange(start: s(6), end: s(8)), start: .zero, mediaDuration: s(8)))
        p.timelines.append(tl)
        var shorter = media()
        shorter.duration = s(5); shorter.info?.duration = s(5)
        p.replaceMedia(m.id, with: shorter)
        #expect(p.timelines[0].tracks[0].clips.isEmpty)
    }
}
