import Foundation
import Testing
@testable import SQCore

private let fd = Time(1001, 30000)

private func pair(videoStart: Int64, audioStart: Int64, vSrc: Int64 = 0, aSrc: Int64 = 0, mediaLen: Int64 = 200,
                  lockAudio: Bool = false) -> (Timeline, Clip, Clip) {
    let media = UUID(), link = UUID()
    var v = Clip(name: "v", media: media, kind: .video, source: TimeRange(start: fd * vSrc, duration: fd * 100),
                 start: fd * videoStart, link: link)
    var a = Clip(name: "a", media: media, kind: .audio, source: TimeRange(start: fd * aSrc, duration: fd * 100),
                 start: fd * audioStart, link: link)
    v.mediaDuration = fd * mediaLen; a.mediaDuration = fd * mediaLen
    var vt = Track(kind: .video), at = Track(kind: .audio)
    try! vt.overwrite(v); try! at.overwrite(a)
    at.isLocked = lockAudio
    return (Timeline(name: "t", frameDuration: fd, tracks: [vt, at]), v, a)
}

@Suite struct SyncFixTests {
    @Test func moveAudioIntoSync() throws {
        var (t, v, a) = pair(videoStart: 10, audioStart: 13)
        try t.moveIntoSync(a.id)
        #expect(t.syncOffsets().isEmpty)
        #expect(t.find(a.id)?.clip.start == fd * 10)
        #expect(t.find(v.id)?.clip.start == fd * 10)
    }

    @Test func moveVideoIntoSyncMovesOnlyVideo() throws {
        var (t, v, a) = pair(videoStart: 10, audioStart: 13)
        try t.moveIntoSync(v.id)
        #expect(t.syncOffsets().isEmpty)
        #expect(t.find(v.id)?.clip.start == fd * 13)
        #expect(t.find(a.id)?.clip.start == fd * 13)
    }

    @Test func slipAudioIntoSync() throws {
        var (t, v, a) = pair(videoStart: 10, audioStart: 13)
        try t.slipIntoSync(a.id)
        #expect(t.syncOffsets().isEmpty)
        let na = t.find(a.id)!.clip
        #expect(na.start == fd * 13 && na.source.start == fd * 3 && na.source.duration == fd * 100)
        #expect(t.find(v.id)?.clip.source.start == .zero)
    }

    @Test func slipVideoIntoSync() throws {
        var (t, v, _) = pair(videoStart: 10, audioStart: 10, vSrc: 5, aSrc: 2)
        try t.slipIntoSync(v.id)
        #expect(t.syncOffsets().isEmpty)
        #expect(t.find(v.id)?.clip.source.start == fd * 2 && t.find(v.id)?.clip.start == fd * 10)
    }

    @Test func slipRefusedWithoutMedia() {
        var (t, _, a) = pair(videoStart: 10, audioStart: 13, mediaLen: 100)
        #expect(throws: EditError.insufficientMedia) { try t.slipIntoSync(a.id) }
        #expect(t.find(a.id)?.clip.source.start == .zero)
    }

    @Test func lockedTrackRefused() {
        var (t, _, a) = pair(videoStart: 10, audioStart: 13, lockAudio: true)
        #expect(throws: EditError.trackLocked) { try t.moveIntoSync(a.id) }
        #expect(throws: EditError.trackLocked) { try t.slipIntoSync(a.id) }
    }

    @Test func inSyncClipIsNoOp() throws {
        var (t, _, a) = pair(videoStart: 10, audioStart: 10)
        let before = t
        try t.moveIntoSync(a.id); try t.slipIntoSync(a.id)
        #expect(t == before)
    }

    @Test func moveBeforeZeroRefused() {
        var (t, v, _) = pair(videoStart: 0, audioStart: 0, aSrc: 5)
        #expect(throws: EditError.collision) { try t.moveIntoSync(v.id) }
        #expect(t.find(v.id)?.clip.start == .zero)
    }
}
