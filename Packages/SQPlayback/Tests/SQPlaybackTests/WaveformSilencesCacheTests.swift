import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

/// Review: results of deleted clips were kept forever (full Clip values).
@Suite struct WaveformSilencesCacheTests {
    @Test func pruneDropsClipsNoLongerOnTheTimeline() {
        let d = UUID()
        let t = DuckSilenceFixture.timeline(dialogue: d, music: UUID())
        let s = WaveformSilences(computesInline: true)
        s.setWaveform(DuckSilenceFixture.waveform(), for: d)
        _ = s.silences(of: t.tracks[0].clips[0], trackVolumeDB: 0)
        #expect(s.cachedCount == 1)
        s.prune(keeping: [t.tracks[0].clips[0].id])
        #expect(s.cachedCount == 1)
        s.prune(keeping: [UUID()])
        #expect(s.cachedCount == 0)
    }

    @Test func cacheIsBounded() {
        let d = UUID()
        let s = WaveformSilences(computesInline: true)
        s.setWaveform(DuckSilenceFixture.waveform(), for: d)
        for _ in 0..<(WaveformSilences.maxEntries + 50) {
            _ = s.silences(of: DuckSilenceFixture.timeline(dialogue: d, music: UUID()).tracks[0].clips[0], trackVolumeDB: 0)
        }
        #expect(s.cachedCount <= WaveformSilences.maxEntries)
    }

    @Test func aHitStillNeedsTheSameClip() throws {
        let d = UUID()
        var t = DuckSilenceFixture.timeline(dialogue: d, music: UUID())
        let s = WaveformSilences(computesInline: true)
        s.setWaveform(DuckSilenceFixture.waveform(), for: d)
        _ = s.silences(of: t.tracks[0].clips[0], trackVolumeDB: 0)
        #expect(s.silences(of: t.tracks[0].clips[0], trackVolumeDB: -40) == [TimeRange(start: .zero, duration: Time(20, 1))])
        _ = try t.move(t.tracks[0].clips[0].id, to: Time(2, 1))
        #expect(s.silences(of: t.tracks[0].clips[0], trackVolumeDB: 0) == [TimeRange(start: Time(7, 1), duration: Time(3, 1))])
    }
}
