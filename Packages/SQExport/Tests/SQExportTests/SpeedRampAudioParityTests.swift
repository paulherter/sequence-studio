import Testing
import Foundation
import SQCore
import SQMedia
import SQAudioFX
import SQPlayback
@testable import SQExport

/// Audio export of a clip with a speed track (a 100 -> 300 % ramp, then 200 % constant) must match live playback, and with
/// pitch not kept both must follow the closed-form source position (`a t + (b - a) t^2 / 2T`, then `+ 2 t`).
@Suite struct SpeedRampAudioParityTests {
    private static let rate = 48_000
    private static let outFrames = 2 * rate                 // 1 s ramp + 1 s constant

    private static func fixture(keepsPitch: Bool) -> (Timeline, Track.ID, UUID) {
        let m = UUID()
        var c = Clip(name: "r", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero,
                     keepsPitch: keepsPitch)
        c.setSpeedKeys(SpeedKeys(segments: [
            SpeedSegment(duration: Time(1, 1), from: ClipSpeed(percent: 100), to: ClipSpeed(percent: 300)),
            SpeedSegment(duration: Time(1, 1), from: ClipSpeed(percent: 200))], origin: .zero))
        let tr = Track(kind: .audio, clips: [c])
        return (Timeline(name: "t", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [tr]), tr.id, m)
    }

    /// Source value = its time in seconds, so the output value is the media position the mixer read.
    private static func media() -> MemoryAudioSource {
        let s = (0..<(5 * rate)).map { Float(Double($0) / Double(rate)) }
        return MemoryAudioSource(left: s, right: s)
    }

    private static func export(keepsPitch: Bool) async throws -> [Float] {
        let (tl, _, m) = fixture(keepsPitch: keepsPitch)
        let src = TimelineAudioSource(timeline: tl, range: TimeRange(start: .zero, duration: Time(2, 1)),
                                      resolver: StaticMediaResolver(audio: [m: media()]))
        var l: [Float] = []
        while let chunk = try await src.nextChunk(maxFrames: 3_000) {
            for i in stride(from: 0, to: chunk.samples.count, by: 2) { l.append(chunk.samples[i]) }
        }
        return l
    }

    private static func playback(keepsPitch: Bool) -> [Float] {
        let (tl, _, m) = fixture(keepsPitch: keepsPitch)
        let source = media()
        let f = AudioFeeder(timeline: tl, ring: RingBuffer(capacity: 1 << 17), blockFrames: 256) { id in
            guard id == m else { throw MediaError.unreadable }
            return source
        }
        f.declickFrames = AudioDeClick.currentFadeFrames()
        f.seek(to: 0, reverse: false)
        _ = f.fill(maxBlocks: (outFrames + 1_024) / 256 + 1)
        let lat = f.flushed.latency
        var l = [Float](repeating: 0, count: outFrames + lat), r = l
        l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in
            _ = f.ring.pop(left: a.baseAddress!, right: b.baseAddress!, count: outFrames + lat) } }
        return Array(l.dropFirst(lat))
    }

    private static func expected(_ frame: Int) -> Double {
        let t = Double(frame) / Double(rate)
        return t <= 1 ? t + t * t : 2 + 2 * (t - 1)     // 100 -> 300 % over 1 s consumes 2 s of media
    }

    @Test(.serialized, arguments: [false, true]) func exportMatchesPlayback(keepsPitch: Bool) async throws {
        let ex = try await Self.export(keepsPitch: keepsPitch), pb = Self.playback(keepsPitch: keepsPitch)
        #expect(ex.count == Self.outFrames && pb.count == Self.outFrames)
        // Stay off the de-clicked edges.
        let inner = 4_000..<(Self.outFrames - 4_000)
        let diff = inner.reduce(Float(0)) { max($0, abs(ex[$1] - pb[$1])) }
        NSLog("speed ramp audio parity (keepsPitch \(keepsPitch)): export vs playback \(diff)")
        #expect(diff < 1e-3, "export vs playback \(diff)")
        if !keepsPitch {
            let off = inner.reduce(0.0) { max($0, abs(Double(ex[$1]) - Self.expected($1))) }
            #expect(off < 1e-3, "export vs closed-form source position \(off)")
        }
    }
}
