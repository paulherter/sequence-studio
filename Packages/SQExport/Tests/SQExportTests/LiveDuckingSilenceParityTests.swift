import Testing
import Foundation
import SQCore
import SQMedia
import SQAudioFX
import SQPlayback
@testable import SQExport

/// N8b: with the same dialogue pauses (one `WaveformSilences`, the app's instance), export and playback duck the music the
/// same way, and the music comes back up inside the pause.
@Suite struct LiveDuckingSilenceParityTests {
    private static let n = 10 * 48_000
    private static let setting = ProjectLiveDucking(isOn: true, amountDB: 12)

    /// 10 s, 10 ms buckets, silent from 3 s to 6 s.
    private static func waveform() -> WaveformData {
        var l0: [Float] = []
        for i in 0..<1000 { l0 += (i >= 300 && i < 600) ? [0, 0] : [-0.5, 0.5] }
        return WaveformData(sampleRate: 1000, channelCount: 1, totalFrames: 10_000, baseBucketSize: 10, levels: [l0])
    }

    private static func fixture() -> (Timeline, dialogue: UUID, music: UUID) {
        let d = UUID(), m = UUID()
        let len = TimeRange(start: .zero, duration: Time(10, 1))
        var dt = Track(kind: .audio, clips: [Clip(name: "d", media: d, kind: .audio, source: len, start: .zero)])
        dt.audioRole = .dialogue
        var mt = Track(kind: .audio, clips: [Clip(name: "m", media: m, kind: .audio, source: len, start: .zero)])
        mt.audioRole = .music
        return (Timeline(name: "t", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [dt, mt]), d, m)
    }

    private static let music = MemoryAudioSource(mono: (0..<n).map { Float(0.4 * sin(2 * Double.pi * 220 * Double($0) / 48_000)) })
    private static let quiet = MemoryAudioSource(mono: [Float](repeating: 0, count: n))

    /// The app's instance after its background work for the dialogue clip is done (what playback hears once warm).
    private static func warmSilences(_ t: Timeline, dialogue d: UUID) async throws -> WaveformSilences {
        let s = WaveformSilences()
        s.setWaveform(waveform(), for: d)
        for _ in 0..<500 {
            if s.silences(of: t.tracks[0].clips[0], trackVolumeDB: 0) != nil { return s }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("background silence analysis never finished"); return s
    }

    private static func export(_ t: Timeline, d: UUID, m: UUID, silences: WaveformSilences) async throws -> [Float] {
        let src = TimelineAudioSource(timeline: t, range: TimeRange(start: .zero, duration: Time(10, 1)), liveDucking: setting,
                                      dialogueSilences: silences,
                                      resolver: StaticMediaResolver(audio: [d: quiet, m: music]))
        var l: [Float] = []
        while let chunk = try await src.nextChunk(maxFrames: 3_000) {
            for i in stride(from: 0, to: chunk.samples.count, by: 2) { l.append(chunk.samples[i]) }
        }
        return l
    }

    private static func playback(_ t: Timeline, d: UUID, m: UUID, silences: WaveformSilences) -> [Float] {
        let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 20), blockFrames: 256) { $0 == d ? quiet : music }
        f.declickFrames = AudioDeClick.currentFadeFrames()
        f.projectLiveDucking = setting
        f.dialogueSilences = silences
        f.seek(to: 0, reverse: false)
        _ = f.fill(maxBlocks: n / 256 + 16)
        let lat = f.flushed.latency
        var l = [Float](repeating: 0, count: n + lat), r = l
        l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in
            _ = f.ring.pop(left: a.baseAddress!, right: b.baseAddress!, count: n + lat) } }
        return Array(l.dropFirst(lat))
    }

    private static func peak(_ x: [Float], _ fromS: Double, _ toS: Double) -> Float {
        x[Int(fromS * 48_000)..<Int(toS * 48_000)].reduce(0) { max($0, abs($1)) }
    }

    @Test func exportMatchesPlaybackAndThePauseReleasesTheMusic() async throws {
        let (t, d, m) = Self.fixture()
        let s = try await Self.warmSilences(t, dialogue: d)
        let e = try await Self.export(t, d: d, m: m, silences: s)
        let p = Self.playback(t, d: d, m: m, silences: s)
        #expect(e.count == Self.n && p.count == Self.n)
        #expect(zip(e, p).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) } < 1e-5)
        // Pause: the music is back up by the duck amount (12 dB); under dialogue it stays ducked.
        let up = Self.peak(e, 4, 5), down = Self.peak(e, 1, 2)
        #expect(up / down > 3)
        #expect(abs(Self.peak(e, 7, 8) - down) < 1e-3)
    }

    /// Without pause data (waveform not read) the whole dialogue clip ducks, as before N8b.
    @Test func withoutWaveformTheWholeClipDucks() async throws {
        let (t, d, m) = Self.fixture()
        let e = try await Self.export(t, d: d, m: m, silences: WaveformSilences())
        #expect(abs(Self.peak(e, 4, 5) - Self.peak(e, 1, 2)) < 1e-3)
    }

    /// Export never depends on background timing: a cold instance (nothing analyzed yet) already hears the pause.
    @Test func coldExportComputesThePausesInline() async throws {
        let (t, d, m) = Self.fixture()
        let s = WaveformSilences()
        s.setWaveform(Self.waveform(), for: d)
        let e = try await Self.export(t, d: d, m: m, silences: s)
        #expect(Self.peak(e, 4, 5) / Self.peak(e, 1, 2) > 3)
    }
}
