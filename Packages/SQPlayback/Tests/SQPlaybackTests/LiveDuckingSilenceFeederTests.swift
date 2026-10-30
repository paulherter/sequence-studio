import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

/// N8b: pauses inside a dialogue clip (from its waveform) release the live duck in the mix.
enum DuckSilenceFixture {
    static let rate: Int64 = 48_000

    /// 20 s of 10 ms buckets at `level`, silent from `pauseStart` for `pauseLength` seconds.
    static func waveform(level: Float = 0.5, pauseStart: Int = 5, pauseLength: Int = 3) -> WaveformData {
        var l0: [Float] = []
        for i in 0..<2000 {
            let silent = i >= pauseStart * 100 && i < (pauseStart + pauseLength) * 100
            l0 += silent ? [0, 0] : [-level, level]
        }
        return WaveformData(sampleRate: 1000, channelCount: 1, totalFrames: 20_000, baseBucketSize: 10, levels: [l0])
    }

    static func timeline(dialogue d: UUID, music m: UUID) -> Timeline {
        let len = TimeRange(start: .zero, duration: Time(20, 1))
        var dt = Track(kind: .audio, clips: [Clip(name: "d", media: d, kind: .audio, source: len, start: .zero)])
        dt.audioRole = .dialogue
        var mt = Track(kind: .audio, clips: [Clip(name: "m", media: m, kind: .audio, source: len, start: .zero)])
        mt.audioRole = .music
        return Timeline(name: "t", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [dt, mt])
    }

    /// Mixer where dialogue is silent (only the music is heard) and music is a constant 0.5.
    static func feeder(_ t: Timeline, dialogue d: UUID) -> AudioFeeder {
        let music = MemoryAudioSource(mono: [Float](repeating: 0.5, count: 20 * Int(rate)))
        let quiet = MemoryAudioSource(mono: [Float](repeating: 0, count: 20 * Int(rate)))
        let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { $0 == d ? quiet : music }
        f.liveDucking = LiveDucking(amountDB: 12)
        return f
    }

    static func sample(_ f: AudioFeeder, _ t: Timeline, at seconds: Double) -> Float {
        var l = [Float](repeating: 0, count: 256), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            f.mix(timeline: t, startFrame: Int64(seconds * Double(rate)), count: 256, left: lp.baseAddress!, right: rp.baseAddress!, clipEffects: false)
        } }
        return l[128]
    }
}

@Suite struct WaveformSilencesTests {
    @Test func inlineProviderFindsThePause() {
        let d = UUID()
        let t = DuckSilenceFixture.timeline(dialogue: d, music: UUID())
        let s = WaveformSilences(computesInline: true)
        #expect(s.silences(of: t.tracks[0].clips[0], trackVolumeDB: 0) == nil)       // no waveform yet
        s.setWaveform(DuckSilenceFixture.waveform(), for: d)
        let p = s.silences(of: t.tracks[0].clips[0], trackVolumeDB: 0)
        #expect(p == [TimeRange(start: Time(5, 1), duration: Time(3, 1))])
    }

    @Test func backgroundProviderNeverBlocksAndDeliversLater() async throws {
        let d = UUID()
        let t = DuckSilenceFixture.timeline(dialogue: d, music: UUID())
        let s = WaveformSilences()
        s.setWaveform(DuckSilenceFixture.waveform(), for: d)
        #expect(s.silences(of: t.tracks[0].clips[0], trackVolumeDB: 0) == nil)       // first ask: queued, whole clip ducks
        s.waitUntilIdle()
        #expect(s.silences(of: t.tracks[0].clips[0], trackVolumeDB: 0) == [TimeRange(start: Time(5, 1), duration: Time(3, 1))])
    }

    @Test func anEditedClipIsRecomputed() throws {
        let d = UUID()
        var t = DuckSilenceFixture.timeline(dialogue: d, music: UUID())
        let s = WaveformSilences(computesInline: true)
        s.setWaveform(DuckSilenceFixture.waveform(), for: d)
        _ = s.silences(of: t.tracks[0].clips[0], trackVolumeDB: 0)
        _ = try t.move(t.tracks[0].clips[0].id, to: Time(1, 1))
        #expect(s.silences(of: t.tracks[0].clips[0], trackVolumeDB: 0) == [TimeRange(start: Time(6, 1), duration: Time(3, 1))])
    }

    @Test func forgettingTheWaveformFallsBackToTheWholeClip() {
        let d = UUID()
        let t = DuckSilenceFixture.timeline(dialogue: d, music: UUID())
        let s = WaveformSilences(computesInline: true)
        s.setWaveform(DuckSilenceFixture.waveform(), for: d)
        _ = s.silences(of: t.tracks[0].clips[0], trackVolumeDB: 0)
        s.setWaveform(nil, for: d)
        #expect(s.silences(of: t.tracks[0].clips[0], trackVolumeDB: 0) == nil)
    }

    @Test func exportViewSharesTheWaveforms() {
        let d = UUID()
        let t = DuckSilenceFixture.timeline(dialogue: d, music: UUID())
        let s = WaveformSilences()
        s.setWaveform(DuckSilenceFixture.waveform(), for: d)
        #expect(s.forExport.silences(of: t.tracks[0].clips[0], trackVolumeDB: 0) == [TimeRange(start: Time(5, 1), duration: Time(3, 1))])
    }
}

@Suite struct LiveDuckingSilenceFeederTests {
    @Test func aPauseInTheDialogueReleasesTheMusic() {
        let d = UUID()
        let t = DuckSilenceFixture.timeline(dialogue: d, music: UUID())
        let f = DuckSilenceFixture.feeder(t, dialogue: d)
        let s = WaveformSilences(computesInline: true)
        s.setWaveform(DuckSilenceFixture.waveform(), for: d)
        f.dialogueSilences = s
        let ducked = Float(0.5 * pow(10, -12.0 / 20))
        #expect(abs(DuckSilenceFixture.sample(f, t, at: 2) - ducked) < 1e-4)
        #expect(abs(DuckSilenceFixture.sample(f, t, at: 6.5) - 0.5) < 1e-4)
        #expect(abs(DuckSilenceFixture.sample(f, t, at: 10) - ducked) < 1e-4)
    }

    @Test func withoutSilenceDataTheWholeClipDucks() {
        let d = UUID()
        let t = DuckSilenceFixture.timeline(dialogue: d, music: UUID())
        let f = DuckSilenceFixture.feeder(t, dialogue: d)
        f.dialogueSilences = WaveformSilences(computesInline: true)      // waveform not read yet
        let ducked = Float(0.5 * pow(10, -12.0 / 20))
        #expect(abs(DuckSilenceFixture.sample(f, t, at: 6.5) - ducked) < 1e-4)
    }
}
