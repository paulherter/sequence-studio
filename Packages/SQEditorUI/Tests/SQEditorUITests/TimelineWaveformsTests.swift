import Foundation
import SQCore
import SQMedia
import Testing
@testable import SQEditorUI

@MainActor @Suite struct TimelineWaveformsTests {
    @Test func audioClipsTriggerOneBuildAndRedraw() async throws {
        let v = VideoTrackInfo(width: 10, height: 10, codec: "x", bitDepth: 8, chroma: "4:2:0",
                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        let a = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")
        let m = MediaRef(name: "m", path: "/nonexistent/m.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(4, 1),
                         info: MediaInfo(duration: Time(4, 1), video: v, audio: a))
        var p = Project(name: "p")
        p.add(m)
        let clip = Clip(name: "m", media: m.id, kind: .audio, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .audio, clips: [clip])])
        let count = Counter()
        let w = TimelineWaveforms { _ in
            count.value += 1
            return WaveformData(sampleRate: 48_000, channelCount: 1, totalFrames: 256, baseBucketSize: 256, levels: [[-0.5, 0.5]])
        }
        var ready = 0
        w.onReady = { ready += 1 }
        w.ensure(timeline: tl, project: p)
        w.ensure(timeline: tl, project: p)      // already pending: no second build
        for _ in 0..<100 where w.data[m.id] == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(w.pendingCount == 0, "pending \(w.pendingCount)")
        #expect(count.value == 1, "builds \(count.value)")
        #expect(ready == 1, "ready \(ready)")
        #expect(w.data[m.id] != nil)
    }
}

private final class Counter: @unchecked Sendable { var value = 0 }
