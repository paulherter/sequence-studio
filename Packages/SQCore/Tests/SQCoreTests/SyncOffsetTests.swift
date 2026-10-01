import Foundation
import Testing
@testable import SQCore

private let fd = Time(1001, 30000)

private func pair(videoStart: Int64, audioStart: Int64, vSrc: Int64 = 0, aSrc: Int64 = 0, mediaA: UUID? = nil,
                  audioLink: UUID? = nil, audioStartTime: Time? = nil, link: UUID = UUID()) -> (Timeline, Clip, Clip) {
    let media = UUID()
    let v = Clip(name: "v", media: media, kind: .video, source: TimeRange(start: fd * vSrc, duration: fd * 100),
                 start: fd * videoStart, link: link)
    let a = Clip(name: "a", media: mediaA ?? media, kind: .audio, source: TimeRange(start: fd * aSrc, duration: fd * 100),
                 start: audioStartTime ?? fd * audioStart, link: audioLink ?? link)
    var vt = Track(kind: .video), at = Track(kind: .audio)
    try! vt.overwrite(v); try! at.overwrite(a)
    return (Timeline(name: "t", frameDuration: fd, tracks: [vt, at]), v, a)
}

@Suite struct SyncOffsetTests {
    @Test func inSyncPairHasNoBadge() {
        let (t, _, _) = pair(videoStart: 10, audioStart: 10)
        #expect(t.syncOffsets().isEmpty)
    }

    @Test func movedAudioShowsPlusOnAudioAndMinusOnVideo() {
        let (t, v, a) = pair(videoStart: 10, audioStart: 13)
        let o = t.syncOffsets()
        #expect(o[a.id] == 3 && o[v.id] == -3)
    }

    @Test func movedEarlierIsNegativeOnAudio() {
        let (t, _, a) = pair(videoStart: 10, audioStart: 7)
        #expect(t.syncOffsets()[a.id] == -3)
    }

    @Test func slippedSourceCountsToo() {
        // Same timeline start, but the audio shows source 5 frames later than the video: 5 frames out of sync.
        let (t, v, a) = pair(videoStart: 10, audioStart: 10, aSrc: 5)
        #expect(t.syncOffsets()[a.id] == -5 && t.syncOffsets()[v.id] == 5)
    }

    @Test func bothMovedTogetherStaysInSync() {
        // Trimming the head of both (start and source move together) keeps them in sync.
        let (t, _, _) = pair(videoStart: 14, audioStart: 14, vSrc: 4, aSrc: 4)
        #expect(t.syncOffsets().isEmpty)
    }

    @Test func differentMediaOrNoLinkIsIgnored() {
        let (t, _, _) = pair(videoStart: 10, audioStart: 13, mediaA: UUID())     // e.g. a voice-over linked on purpose
        #expect(t.syncOffsets().isEmpty)
        let (u, _, _) = pair(videoStart: 10, audioStart: 13, audioLink: UUID())    // different link groups
        #expect(u.syncOffsets().isEmpty)
    }

    @Test func subFrameDifferenceRoundsToZero() {
        let (t, _, _) = pair(videoStart: 10, audioStart: 10, audioStartTime: fd * 10 + Time(1, 100_000))
        #expect(t.syncOffsets().isEmpty)
    }
}
