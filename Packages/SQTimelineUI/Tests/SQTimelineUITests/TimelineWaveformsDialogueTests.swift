import Foundation
import SQCore
import SQMedia
import SQPlayback
import Testing
@testable import SQTimelineUI

/// Review: export/bake right after open (or of a sequence never shown) ducked whole clips because the waveform was not
/// built yet. `prepareDialogue` builds (or waits for) the dialogue waveforms first, so the pauses are heard.
@MainActor @Suite struct TimelineWaveformsDialogueTests {
    static func fixture() -> (Project, Timeline) {
        let a = AudioTrackInfo(sampleRate: 48_000, channels: 1, codec: "lpcm")
        let m = MediaRef(name: "d", path: "/nonexistent/d.wav", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1),
                         info: MediaInfo(duration: Time(10, 1), video: nil, audio: a))
        var p = Project(name: "p")
        p.add(m)
        var dt = Track(kind: .audio, clips: [Clip(name: "d", media: m.id, kind: .audio,
                                                  source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)])
        dt.audioRole = .dialogue
        return (p, Timeline(name: "t", frameDuration: Time(1, 30), tracks: [dt]))
    }

    @Test func prepareDialogueBuildsTheWaveformsBeforeExport() async throws {
        let (p, tl) = Self.fixture()
        let w = TimelineWaveforms { _ in
            try await Task.sleep(for: .milliseconds(50))
            var l0: [Float] = []
            for i in 0..<1000 { l0 += (i >= 300 && i < 600) ? [0, 0] : [-0.5, 0.5] }
            return WaveformData(sampleRate: 1000, channelCount: 1, totalFrames: 10_000, baseBucketSize: 10, levels: [l0])
        }
        let s = await w.prepareDialogue(of: tl, project: p)
        #expect(s.forExport.silences(of: tl.tracks[0].clips[0], trackVolumeDB: 0) == [TimeRange(start: Time(3, 1), duration: Time(3, 1))])
    }

    @Test func prepareDialogueWaitsForABuildAlreadyRunning() async throws {
        let (p, tl) = Self.fixture()
        let count = BuildCount()
        let w = TimelineWaveforms { _ in
            count.value += 1
            try await Task.sleep(for: .milliseconds(80))
            return WaveformData(sampleRate: 1000, channelCount: 1, totalFrames: 10_000, baseBucketSize: 10,
                                levels: [[Float](repeating: 0.5, count: 2000)])
        }
        w.ensure(timeline: tl, project: p)                  // the timeline started it
        let s = await w.prepareDialogue(of: tl, project: p)
        #expect(count.value == 1)
        #expect(s.forExport.silences(of: tl.tracks[0].clips[0], trackVolumeDB: 0) == [])
    }

    /// Media that cannot be analyzed fail safe: prepare returns, the clip ducks whole.
    @Test func prepareDialogueFailsSafe() async throws {
        let (p, tl) = Self.fixture()
        let w = TimelineWaveforms { _ in throw CocoaError(.fileNoSuchFile) }
        let s = await w.prepareDialogue(of: tl, project: p)
        #expect(s.forExport.silences(of: tl.tracks[0].clips[0], trackVolumeDB: 0) == nil)
    }
}

private final class BuildCount: @unchecked Sendable { var value = 0 }
