import Testing
import Foundation
import SSCore
import SSMedia
@testable import SSPlayback

private let rate: Int64 = 48_000
private let fmt = SequenceFormat(frameDuration: Time(1001, 30_000))
private func frames(_ n: Int64) -> Time { Time(n, rate) }

private func retimedClip(_ media: UUID, src: Int64 = 0, srcLen: Int64, at: Int64 = 0, speed: ClipSpeed,
                         reversed: Bool = false, keepsPitch: Bool) -> Clip {
    Clip(name: "c", media: media, kind: .audio, source: TimeRange(start: frames(src), duration: frames(srcLen)),
         start: frames(at), speed: speed, reversed: reversed, keepsPitch: keepsPitch)
}
private func render(_ t: Timeline, _ src: MemoryAudioSource, _ m: UUID, from: Int64, count: Int, block: Int = 4096) -> [Float] {
    let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: block) { _ in src }
    var l = [Float](repeating: 9, count: count), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        f.mix(timeline: t, startFrame: from, count: count, left: lp.baseAddress!, right: rp.baseAddress!) } }
    return l
}
private func tl(_ c: Clip) -> Timeline { Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [c])]) }
private func ramp(_ n: Int) -> MemoryAudioSource { MemoryAudioSource(mono: (0..<n).map { Float($0) + 1 }) }
private func sine(_ n: Int, hz: Double) -> MemoryAudioSource {
    MemoryAudioSource(mono: (0..<n).map { Float(sin(2 * Double.pi * hz * Double($0) / 48_000)) })
}
private func risingCrossings(_ x: ArraySlice<Float>) -> Int {
    zip(x, x.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
}

@Suite struct AudioRetimeTests {
    @Test func doubleSpeedResamplesEveryOtherSource() {
        let m = UUID()
        let t = tl(retimedClip(m, srcLen: 2000, speed: ClipSpeed(percent: 200), keepsPitch: false))
        let o = render(t, ramp(5000), m, from: 0, count: 1200)
        for i in 0..<1000 { #expect(o[i] == Float(2 * i) + 1, "frame \(i)") }
        #expect(o[1000] == 0 && o[1199] == 0)
    }

    @Test func reverseAtNormalSpeedIsBitExactMirror() {
        let m = UUID()
        let t = tl(retimedClip(m, src: 100, srcLen: 100, at: 50, speed: .normal, reversed: true, keepsPitch: true))
        let o = render(t, ramp(1000), m, from: 0, count: 300)
        #expect(o[49] == 0 && o[150] == 0)
        for i in 0..<100 { #expect(o[50 + i] == Float(200 - i), "frame \(i)") }       // source index 199 - i holds 200 - i
    }

    @Test func reverseAt200() {
        let m = UUID()
        let t = tl(retimedClip(m, src: 0, srcLen: 200, speed: ClipSpeed(percent: 200), reversed: true, keepsPitch: false))
        let o = render(t, ramp(1000), m, from: 0, count: 120)
        for i in 0..<100 { #expect(o[i] == Float(200 - 2 * i), "frame \(i)") }          // index 199 - 2i holds 200 - 2i
    }

    @Test func blockSplitGivesIdenticalSamples() {
        let m = UUID()
        for (pct, rev) in [(200.0, false), (50.0, false), (200.0, true), (33.33, true)] {
            let t = tl(retimedClip(m, src: 4000, srcLen: 24000, at: 700, speed: ClipSpeed(percent: pct), reversed: rev, keepsPitch: true))
            let src = sine(60000, hz: 300)
            let whole = render(t, src, m, from: 0, count: 8192, block: 8192)
            var pieces: [Float] = []
            for s in stride(from: Int64(0), to: 8192, by: 1000) { pieces += render(t, src, m, from: s, count: min(1000, 8192 - Int(s)), block: 1024) }
            #expect(pieces == whole, "\(pct)% reversed=\(rev)")
        }
    }

    @Test func timeStretchKeepsPitchAndResampleChangesIt() {
        let m = UUID()
        let src = sine(200_000, hz: 440)
        let kept = tl(retimedClip(m, src: 0, srcLen: 96_000, speed: ClipSpeed(percent: 200), keepsPitch: true))
        let resampled = tl(retimedClip(m, src: 0, srcLen: 96_000, speed: ClipSpeed(percent: 200), keepsPitch: false))
        let a = render(kept, src, m, from: 0, count: 8192, block: 8192)
        let b = render(resampled, src, m, from: 0, count: 8192, block: 8192)
        let window = 4096..<8192                                         // 85.3 ms: 440 Hz = 37.5 cycles
        let ca = risingCrossings(a[window]), cb = risingCrossings(b[window])
        #expect((35...40).contains(ca), "pitch kept: \(ca) cycles")
        #expect((72...78).contains(cb), "pitch doubled: \(cb) cycles")
    }

    @Test func slowedDownStretchKeepsLevelAndPitch() {
        let m = UUID()
        let src = sine(200_000, hz: 440)
        let t = tl(retimedClip(m, src: 0, srcLen: 48_000, speed: ClipSpeed(percent: 50), keepsPitch: true))   // 2 s
        let o = render(t, src, m, from: 0, count: 8192, block: 8192)
        let body = o[2048..<8192]
        #expect(body.map { abs($0) }.max()! > 0.9 && body.map { abs($0) }.max()! < 1.1)
        #expect((54...59).contains(risingCrossings(o[2048..<8192])), "cycles \(risingCrossings(o[2048..<8192]))")   // 128 ms * 440
    }

    @Test func firstHopHasNoFadeIn() {
        let m = UUID()
        let src = MemoryAudioSource(mono: [Float](repeating: 1, count: 100_000))
        let t = tl(retimedClip(m, src: 10_000, srcLen: 20_000, speed: ClipSpeed(percent: 200), keepsPitch: true))
        let o = render(t, src, m, from: 0, count: 4096, block: 4096)
        #expect(o[0] == 1 && o[500] == 1)
        #expect(abs(o[3000] - 1) < 1e-5)
    }
}

/// Audio Gain is part of `Clip.volume(at:)`, which every path uses: retimed and reversed output is gain x volume, once.
@Suite struct AudioGainRetimeTests {
    @Test func gainTimesVolumeAppliesOnceWhenRetimedAndReversed() {
        let m = UUID()
        for (speed, rev) in [(200, false), (200, true), (50, false), (100, true)] {
            func clip(gain: Double, volume: Double) -> Clip {
                var c = retimedClip(m, srcLen: 4000, speed: ClipSpeed(percent: Double(speed)), reversed: rev, keepsPitch: false)
                c.audioGainDB = gain
                c.animation.volume = AnimatedProperty(volume)
                return c
            }
            let base = render(tl(clip(gain: 0, volume: 1)), ramp(8000), m, from: 0, count: 1000)
            let gained = render(tl(clip(gain: 6.0206, volume: 1)), ramp(8000), m, from: 0, count: 1000)
            let both = render(tl(clip(gain: 6.0206, volume: 0.5)), ramp(8000), m, from: 0, count: 1000)
            for i in stride(from: 0, to: 1000, by: 37) {
                #expect(abs(gained[i] - base[i] * 2) <= abs(base[i]) * 1e-3 + 1e-4, "gain x2 at \(i), \(speed)% rev \(rev)")
                #expect(abs(both[i] - base[i]) <= abs(base[i]) * 1e-3 + 1e-4, "gain x volume once at \(i)")
            }
            #expect(base.contains { $0 != 0 })
        }
    }
}

