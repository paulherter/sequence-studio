import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

private let rate: Int64 = 48_000
private let fmt = SequenceFormat(frameDuration: Time(1001, 30_000))
private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }

/// An audio clip with a speed track (1 s = 48000 output frames per `seconds`).
private func keyedClip(_ media: UUID, _ segs: [SpeedSegment], origin: Time = .zero, keepsPitch: Bool, at: Time = .zero) -> Clip {
    var c = Clip(name: "k", media: media, kind: .audio, source: TimeRange(start: origin, duration: Time(1, 1)), start: at, keepsPitch: keepsPitch)
    c.setSpeedKeys(SpeedKeys(segments: segs, origin: origin))
    return c
}
private func render(_ c: Clip, _ src: MemoryAudioSource, from: Int64, count: Int, block: Int = 4096) -> [Float] {
    let t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [c])])
    let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: block) { _ in src }
    var l = [Float](repeating: 9, count: count), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        f.mix(timeline: t, startFrame: from, count: count, left: lp.baseAddress!, right: rp.baseAddress!) } }
    return l
}
private func ramp(_ n: Int) -> MemoryAudioSource { MemoryAudioSource(mono: (0..<n).map { Float($0) + 1 }) }
private func sine(_ n: Int, hz: Double) -> MemoryAudioSource {
    MemoryAudioSource(mono: (0..<n).map { Float(sin(2 * Double.pi * hz * Double($0) / 48_000)) })
}
private func risingCrossings(_ x: ArraySlice<Float>) -> Int { zip(x, x.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count }

@Suite struct SpeedKeysAudioTests {
    @Test func resampleFollowsTheTwoSegments() {
        let m = UUID()
        let c = keyedClip(m, [SpeedSegment(duration: Time(1, 48), from: pct(100)),         // 1000 output frames at 100 %
                              SpeedSegment(duration: Time(1, 48), from: pct(200))], keepsPitch: false)
        let o = render(c, ramp(10_000), from: 0, count: 2100)
        for i in 0..<1000 { #expect(abs(o[i] - Float(i + 1)) < 1e-3, "frame \(i)") }
        for j in 0..<900 { #expect(abs(o[1000 + j] - Float(1000 + 2 * j + 1)) < 1e-3, "frame \(1000 + j)") }
    }

    @Test func sourceFollowsTheRampClosedForm() {
        // 100 % -> 300 % over 2000 output frames: source(o) = o + (2/2) o^2 / 2000 = o + o^2 / 2000 (in frames).
        let m = UUID()
        let c = keyedClip(m, [SpeedSegment(duration: Time(2000, 48_000), from: pct(100), to: pct(300))], keepsPitch: false)
        let o = render(c, ramp(20_000), from: 0, count: 2000)
        for i in stride(from: 0, to: 2000, by: 97) {
            let want = Double(i) + Double(i * i) / 2000 + 1
            #expect(abs(Double(o[i]) - want) < 0.01, "frame \(i)")
        }
    }

    @Test func pitchIsKeptAcrossARampOnlyWhenAsked() {
        let m = UUID()
        let segs = [SpeedSegment(duration: Time(1, 1), from: pct(100)), SpeedSegment(duration: Time(1, 1), from: pct(200))]
        let src = sine(200_000, hz: 440)
        let kept = render(keyedClip(m, segs, keepsPitch: true), src, from: 0, count: 96_000, block: 96_000)
        let varispeed = render(keyedClip(m, segs, keepsPitch: false), src, from: 0, count: 96_000, block: 96_000)
        // second second: 440 Hz kept vs 880 Hz when the pitch follows the speed
        let k = risingCrossings(kept[52_000..<92_000]), v = risingCrossings(varispeed[52_000..<92_000])
        #expect(abs(Double(k) / (40_000.0 / 48_000.0) - 440) < 30, "kept: \(k)")
        #expect(abs(Double(v) / (40_000.0 / 48_000.0) - 880) < 40, "varispeed: \(v)")
    }

    @Test func blockSplitGivesIdenticalSamples() {
        let m = UUID()
        let segs = [SpeedSegment(duration: Time(1, 4), from: pct(80)), SpeedSegment(duration: Time(1, 4), from: pct(80), to: pct(300)),
                    SpeedSegment(duration: Time(1, 4), from: pct(300), reversed: false)]
        for keeps in [true, false] {
            let c = keyedClip(m, segs, origin: Time(4000, 48_000), keepsPitch: keeps, at: Time(700, 48_000))
            let src = sine(120_000, hz: 300)
            let whole = render(c, src, from: 0, count: 8192, block: 8192)
            var pieces: [Float] = []
            for s in stride(from: Int64(0), to: 8192, by: 1000) { pieces += render(c, src, from: s, count: min(1000, 8192 - Int(s)), block: 1024) }
            #expect(pieces == whole, "keepsPitch \(keeps)")
        }
    }

    @Test func oneSegmentTrackMatchesTheConstantClip() {
        let m = UUID()
        var plain = Clip(name: "p", media: m, kind: .audio, source: TimeRange(start: Time(2000, 48_000), duration: Time(4000, 48_000)),
                         start: .zero, speed: pct(200), keepsPitch: false)
        let want = render(plain, ramp(20_000), from: 0, count: 2100)
        plain.speedKeys = SpeedKeys.of(plain)
        let got = render(plain, ramp(20_000), from: 0, count: 2100)
        for i in 0..<2100 { #expect(abs(got[i] - want[i]) < 1e-3, "frame \(i)") }
    }

    @Test func reversedSegmentPlaysBackwards() {
        let m = UUID()
        let c = keyedClip(m, [SpeedSegment(duration: Time(1000, 48_000), from: pct(100)),
                              SpeedSegment(duration: Time(500, 48_000), from: pct(100), reversed: true)], keepsPitch: false)
        let o = render(c, ramp(5000), from: 0, count: 1600)
        #expect(abs(o[999] - 1000) < 1e-3)
        #expect(o[1100] < o[1010] && o[1010] < o[999] + 1)
    }
}
