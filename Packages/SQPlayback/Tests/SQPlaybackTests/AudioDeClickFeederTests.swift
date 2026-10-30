import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

private let rate: Int64 = 48_000
private let fmt = SequenceFormat(frameDuration: Time(1001, 30_000))
private func frames(_ n: Int64) -> Time { Time(n, rate) }
private func clip(_ media: UUID, len: Int64, at start: Int64) -> Clip {
    Clip(name: "c", media: media, kind: .audio, source: TimeRange(start: .zero, duration: frames(len)), start: frames(start))
}
private func make(_ t: Timeline, _ sources: [UUID: any AudioSource], fade: Int, block: Int = 8192) -> AudioFeeder {
    let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: block) { id in
        guard let s = sources[id] else { throw MediaError.unreadable }
        return s
    }
    f.declickFrames = fade
    return f
}
private func mixed(_ f: AudioFeeder, _ t: Timeline, from: Int64, count: Int) -> [Float] {
    var l = [Float](repeating: 9, count: count), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        f.mix(timeline: t, startFrame: from, count: count, left: lp.baseAddress!, right: rp.baseAddress!, clipEffects: false) } }
    return l
}

@Suite struct AudioDeClickFeederTests {
    /// Two loud DC clips of opposite sign, butted together: a hard cut with a full-scale jump.
    private func hardCut() -> (Timeline, [UUID: any AudioSource]) {
        let a = UUID(), b = UUID()
        let t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio,
            clips: [clip(a, len: 2000, at: 1000), clip(b, len: 2000, at: 3000)])])
        return (t, [a: MemoryAudioSource(mono: [Float](repeating: 0.8, count: 4000)),
                    b: MemoryAudioSource(mono: [Float](repeating: -0.8, count: 4000))])
    }
    private func maxStep(_ x: [Float]) -> Float { zip(x, x.dropFirst()).map { abs($1 - $0) }.max() ?? 0 }

    @Test func withoutFadeTheHardCutJumps() {
        let (t, s) = hardCut()
        let o = mixed(make(t, s, fade: 0), t, from: 0, count: 5000)
        #expect(maxStep(o) >= 1.6 - 0.001)      // 0.8 -> -0.8 in one sample
    }

    @Test func withFadeNoDiscontinuityAtCutOrClipEdges() {
        let (t, s) = hardCut()
        let o = mixed(make(t, s, fade: 144), t, from: 0, count: 5000)
        #expect(maxStep(o) <= 0.8 / 144 + 1e-6)
        #expect(o[2999] == 0 && o[3000] == 0)             // silent on both sides of the cut
        #expect(o[1000] == 0 && o[4999] == 0)             // outer edges too
        #expect(o[1500] == 0.8 && o[3500] == -0.8)        // interior untouched
    }

    @Test func blockSplitGivesIdenticalSamples() {
        // Playback blocks and export blocks differ in size; the samples must not.
        let (t, s) = hardCut()
        let whole = mixed(make(t, s, fade: 144, block: 8192), t, from: 0, count: 5000)
        let f = make(t, s, fade: 144, block: 700)
        var pieces: [Float] = []
        for st in stride(from: Int64(0), to: 5000, by: 700) { pieces += mixed(f, t, from: st, count: Int(min(700, 5000 - st))) }
        #expect(pieces == whole)
    }

    @Test func fillPathFadesToo() {
        // The feeder thread path (playback and export) goes through the same mix as `mix`.
        let (t, s) = hardCut()
        let f = make(t, s, fade: 144, block: 1000)
        f.seek(to: 0, reverse: false)
        _ = f.fill(maxBlocks: 5)
        var l = [Float](repeating: 0, count: 5000), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: 5000) } }
        #expect(maxStep(l) <= 0.8 / 144 + 1e-6)
        #expect(l[2999] == 0 && l[3000] == 0)
    }
}

/// Bleep: the tone laid by `Timeline.bleep` plays through the feeder's one mix path, fades at both edges and the dialog under it is off.
@Suite struct BleepFeederTests {
    @Test func toneReplacesTheDialogCleanlyAtTheEdges() throws {
        let talk = UUID()
        let t0 = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio,
            clips: [Clip(name: "talk", media: talk, kind: .audio, source: TimeRange(start: .zero, duration: frames(12_000)),
                         start: .zero, mediaDuration: frames(12_000))])])
        var t = t0
        let range = TimeRange(start: frames(4000), end: frames(8000))
        try t.bleep(range, tracks: [t.tracks[0].id])
        let f = make(t, [talk: MemoryAudioSource(mono: [Float](repeating: 0.5, count: 12_000))], fade: 144)
        let o = mixed(f, t, from: 0, count: 12_000)
        let a = Float(pow(10.0, -12.0 / 20))
        // Dialog before and after, untouched in the middle of each piece.
        #expect(o[1000] == 0.5 && o[11_000] == 0.5)
        // Tone in the middle of the bleep: exact sine samples (phase counted from the tone clip's start).
        for k in stride(from: 500, to: 3500, by: 37) {
            #expect(abs(o[4000 + k] - a * Float(sin(2 * Double.pi * Double(k) / 48))) < 1e-5)
        }
        // No click anywhere: the largest sample step is the dialog's own fade slope or the sine's slope, never a jump.
        let step = zip(o, o.dropFirst()).map { abs($1 - $0) }.max()!
        #expect(step <= max(0.5 / 144, a * 2 * Float.pi / 48) + 1e-5)
        // Both edges of the bleep reach silence between dialog and tone.
        #expect(o[3999] == 0 || abs(o[3999]) < 0.5 / 144 + 1e-5)
        #expect(abs(o[4000]) < 1e-6 && abs(o[7999]) < a * 0.1)
    }
}
