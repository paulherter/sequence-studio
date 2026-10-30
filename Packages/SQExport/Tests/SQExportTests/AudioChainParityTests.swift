import Testing
import Foundation
import SQCore
import SQMedia
import SQAudioFX
import SQPlayback
@testable import SQExport

/// One audio chain everywhere: clip edge de-click -> clip volume -> track FX (denoise -> compressor). Export
/// (`TimelineAudioSource`), live playback (`AudioFeeder` at another block size, configured like `AudioEngine`) and the
/// stand-alone offline chain (`OfflineAudioFX`, fed the de-clicked clip, since edge fades are a timeline step) must
/// produce the same samples for a clip with volume on a track with a compressing preset.
@Suite struct AudioChainParityTests {
    private static let n = 48_000
    private static let volumeDB = 12.0      // loud clip: drives the compressor harder, so the order is audible

    private static func signal() -> (l: [Float], r: [Float]) {
        let l = (0..<n).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 48_000) + 0.1 * sin(2 * Double.pi * 3_100 * Double($0) / 48_000)) }
        let r = (0..<n).map { Float(0.2 * sin(2 * Double.pi * 180 * Double($0) / 48_000) + 0.15 * sin(2 * Double.pi * 1_200 * Double($0) / 48_000)) }
        return (l, r)
    }

    private static func squash(noiseReduction: Double, gate: NoiseGateSettings = .off, ratio: Double = 6) -> TrackAudioPreset {
        TrackAudioPreset(id: "t.squash", name: "squash",
                         compressor: MultibandCompressorSettings(
                            crossoversHz: [120, 700, 3000],
                            bands: Array(repeating: .init(thresholdDB: -24, ratio: ratio, attackMs: 2, releaseMs: 80), count: 4)),
                         noiseReduction: noiseReduction, gate: gate)
    }

    private static func fixture() -> (Timeline, Track.ID, UUID) {
        let m = UUID()
        var c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(Int64(n), 48_000)), start: .zero)
        c.animation.volume = AnimatedProperty(pow(10, volumeDB / 20))
        let tr = Track(kind: .audio, clips: [c])
        let tl = Timeline(name: "t", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [tr])
        return (tl, tr.id, m)
    }

    private static func export(_ preset: TrackAudioPreset) async throws -> (l: [Float], r: [Float]) {
        let (tl, track, m) = fixture(), s = signal()
        let src = TimelineAudioSource(timeline: tl, range: TimeRange(start: .zero, duration: Time(1, 1)), presets: [track: preset],
                                      resolver: StaticMediaResolver(audio: [m: MemoryAudioSource(left: s.l, right: s.r)]))
        var l: [Float] = [], r: [Float] = []
        while let chunk = try await src.nextChunk(maxFrames: 3_000) {
            for i in stride(from: 0, to: chunk.samples.count, by: 2) { l.append(chunk.samples[i]); r.append(chunk.samples[i + 1]) }
        }
        return (l, r)
    }

    private static func playback(_ preset: TrackAudioPreset) -> (l: [Float], r: [Float]) {
        let (tl, track, m) = fixture(), s = signal()
        let source = MemoryAudioSource(left: s.l, right: s.r)
        let f = AudioFeeder(timeline: tl, ring: RingBuffer(capacity: 1 << 17), blockFrames: 256) { id in
            guard id == m else { throw MediaError.unreadable }
            return source
        }
        f.declickFrames = AudioDeClick.currentFadeFrames()   // as AudioEngine and TimelineAudioSource set it
        f.setTracks([track: preset])
        f.seek(to: 0, reverse: false)
        _ = f.fill(maxBlocks: (n + 1_024) / 256 + 1)
        let lat = f.flushed.latency
        var l = [Float](repeating: 0, count: n + lat), r = l
        l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in
            _ = f.ring.pop(left: a.baseAddress!, right: b.baseAddress!, count: n + lat) } }
        return (Array(l.dropFirst(lat)), Array(r.dropFirst(lat)))
    }

    private static func offline(_ preset: TrackAudioPreset) throws -> (l: [Float], r: [Float]) {
        let s = signal(), fade = AudioDeClick.currentFadeFrames()
        // The clip's edge fades (the clip covers frames 0..<n), applied before the clip volume like the mixer does.
        let edge = (0..<n).map { AudioDeClick.edgeGain(frame: Int64($0), start: 0, end: Int64(n), fade: fade) }
        let l = zip(s.l, edge).map { $0 * $1 }, r = zip(s.r, edge).map { $0 * $1 }
        var fx = try OfflineAudioFX(volume: VolumeAutomation(staticDB: volumeDB), preset: preset, sampleRate: 48_000, channelCount: 2)
        let out = fx.render([l, r], start: .zero).channels
        return (out[0], out[1])
    }

    private static func maxDiff(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    @Test(.serialized, arguments: [0.0, 1.0]) func exportPlaybackAndOfflineChainAgree(noiseReduction: Double) async throws {
        let preset = Self.squash(noiseReduction: noiseReduction)
        let ex = try await Self.export(preset), pb = Self.playback(preset), off = try Self.offline(preset)
        #expect(ex.l.count == Self.n && pb.l.count == Self.n && off.l.count == Self.n)
        // The compressor must actually work on this material, or the test proves nothing about the order.
        let dry = Self.signal(), gain = Float(pow(10, Self.volumeDB / 20))
        #expect(Self.maxDiff(off.l, dry.l.map { $0 * gain }) > 0.1)
        let tol: Float = 1e-4
        let exPb = max(Self.maxDiff(ex.l, pb.l), Self.maxDiff(ex.r, pb.r))
        let exOff = max(Self.maxDiff(ex.l, off.l), Self.maxDiff(ex.r, off.r))
        NSLog("audio parity (nr \(noiseReduction)): export vs playback \(exPb), export vs offline \(exOff)")
        #expect(exPb < tol, "export vs playback \(exPb)")
        #expect(exOff < tol, "export vs offline chain \(exOff)")
    }

    /// The track gate (hold, range, threshold) acts the same in export, live playback and the offline chain.
    @Test(.serialized) func gateHoldAndRangeAgreeAcrossExportPlaybackAndOffline() async throws {
        // Threshold sits inside the signal's level swing so the gate really opens and closes.
        let gate = NoiseGateSettings(enabled: true, thresholdDB: 2, reductionDB: 30, attackMs: 1, holdMs: 5, releaseMs: 40)
        let preset = Self.squash(noiseReduction: 0, gate: gate, ratio: 1), plain = Self.squash(noiseReduction: 0, ratio: 1)
        let ex = try await Self.export(preset), pb = Self.playback(preset), off = try Self.offline(preset)
        let ungated = try Self.offline(plain)
        #expect(Self.maxDiff(off.l, ungated.l) > 0.05, "gate must change the signal or the test proves nothing")
        let tol: Float = 1e-4
        #expect(max(Self.maxDiff(ex.l, pb.l), Self.maxDiff(ex.r, pb.r)) < tol)
        #expect(max(Self.maxDiff(ex.l, off.l), Self.maxDiff(ex.r, off.r)) < tol)
    }
}
