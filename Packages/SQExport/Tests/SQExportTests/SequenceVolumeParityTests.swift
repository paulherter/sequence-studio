import Testing
import Foundation
import SQCore
import SQMedia
import SQAudioFX
import SQPlayback
@testable import SQExport

/// Sequence Volume (`Timeline.masterVolumeDB`, v66): export (`TimelineAudioSource`) and live playback (`AudioFeeder` at another
/// block size) produce the same samples, and both are the 0 dB mix scaled by the level.
@Suite struct SequenceVolumeParityTests {
    private static let n = 24_000

    private static func signal() -> [Float] {
        (0..<n).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 48_000) + 0.1 * sin(2 * Double.pi * 2_900 * Double($0) / 48_000)) }
    }

    private static func fixture(masterDB: Double, media m: UUID) -> Timeline {
        let c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(Int64(n), 48_000)), start: .zero)
        var tr = Track(kind: .audio, clips: [c])
        tr.volumeDB = -1.5; tr.pan = 0.3
        var t = Timeline(name: "t", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [tr])
        t.masterVolumeDB = masterDB
        return t
    }

    private static func export(masterDB: Double) async throws -> [Float] {
        let m = UUID()
        let src = TimelineAudioSource(timeline: fixture(masterDB: masterDB, media: m), range: TimeRange(start: .zero, duration: Time(1, 2)),
                                      resolver: StaticMediaResolver(audio: [m: MemoryAudioSource(mono: signal())]))
        var out: [Float] = []
        while let chunk = try await src.nextChunk(maxFrames: 3_000) { out += chunk.samples }   // interleaved L R
        return out
    }

    private static func playback(masterDB: Double) -> [Float] {
        let m = UUID(), source = MemoryAudioSource(mono: signal())
        let t = fixture(masterDB: masterDB, media: m)
        let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 16), blockFrames: 256) { _ in source }
        f.declickFrames = AudioDeClick.currentFadeFrames()
        f.seek(to: 0, reverse: false)
        _ = f.fill(maxBlocks: n / 256 + 1)
        var l = [Float](repeating: 0, count: n), r = l
        l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in
            _ = f.ring.pop(left: a.baseAddress!, right: b.baseAddress!, count: n) } }
        return zip(l, r).flatMap { [$0, $1] }
    }

    @Test func exportAndPlaybackApplyTheSameLevel() async throws {
        let ex = try await Self.export(masterDB: -6.0206), pb = Self.playback(masterDB: -6.0206)
        let unity = try await Self.export(masterDB: 0)
        #expect(ex.count == 2 * Self.n && pb.count == ex.count && unity.count == ex.count)
        #expect(unity.contains { abs($0) > 0.1 })
        let parity = zip(ex, pb).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        let halved = zip(ex, unity).reduce(Float(0)) { max($0, abs($1.0 - $1.1 * 0.5)) }
        #expect(parity < 1e-6, "export vs playback \(parity)")
        #expect(halved < 1e-5, "export vs half of 0 dB \(halved)")
    }
}
