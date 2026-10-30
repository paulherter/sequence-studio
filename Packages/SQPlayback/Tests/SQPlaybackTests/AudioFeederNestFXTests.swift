import Testing
import Foundation
import SQCore
import SQMedia
import SQAudioFX
@testable import SQPlayback

// Audio FX follow-ups: effects on a nested-sequence clip run on the nest's summed sound (one bus, like Premiere), Audio Gain
// before them, Volume after; scrubbing hears clip effects too. Playback and export share `fill`, so one test covers both.

private let rate: Int64 = 48_000
private let fmt = SequenceFormat(frameDuration: Time(1, 30))
private func frames(_ n: Int64) -> Time { Time(n, rate) }
private let wobble = (0..<30_000).map { Float(0.05 * sin(Double($0) * 0.013) + 0.02 * sin(Double($0) * 0.31)) }

/// Inner sequence: two audio tracks, one clip each (media a, b). Outer: one nest clip of it with `configure` applied.
private func nested(effects: [(String, [String: Double], Bool)], _ configure: (inout Clip) -> Void = { _ in })
    -> (outer: Timeline, seqs: [Timeline.ID: Timeline], a: UUID, b: UUID) {
    let a = UUID(), b = UUID()
    func clip(_ m: UUID) -> Clip { Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: frames(20_000)), start: .zero) }
    let inner = Timeline(name: "inner", format: fmt, tracks: [Track(kind: .audio, clips: [clip(a)]), Track(kind: .audio, clips: [clip(b)])])
    var nest = Clip(name: "n", media: inner.id, kind: .audio, source: TimeRange(start: .zero, duration: frames(20_000)),
                    start: .zero, sequence: inner.id)
    configure(&nest)
    for (kind, values, enabled) in effects {
        guard let id = nest.addEffect(kind: kind) else { continue }
        for (k, v) in values { nest.setParameter(id, k, to: v) }
        if let i = nest.effects.firstIndex(where: { $0.id == id }) { nest.effects[i].enabled = enabled }
    }
    return (Timeline(name: "outer", format: fmt, tracks: [Track(kind: .audio, clips: [nest])]), [inner.id: inner], a, b)
}

private func play(_ t: Timeline, seqs: [Timeline.ID: Timeline], sources: [UUID: [Float]], from: Int64 = 0, count: Int = 4096) -> [Float] {
    let srcs = sources.mapValues { MemoryAudioSource(mono: $0) }
    let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { srcs[$0]! }
    f.setTimeline(t, sequences: seqs)
    f.seek(to: from, reverse: false)
    _ = f.fill(maxBlocks: 8)
    var l = [Float](repeating: 0, count: count), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: count) } }
    return l
}

private let limit = (ClipEffect.audioLimiterKind, [ClipEffect.limiterCeilingKey: -6.0206], true)

@Suite struct AudioFeederNestFXTests {
    /// 0.4 + 0.4 on two inner tracks: a limiter on the nest clip holds the sum at -6 dBFS (0.5). Per inner clip it would
    /// not touch either (0.4 each, 0.8 summed).
    @Test func nestEffectsRunOnTheSummedNest() {
        let n = nested(effects: [limit])
        let x = [Float](repeating: 0.4, count: 30_000)
        let out = play(n.outer, seqs: n.seqs, sources: [n.a: x, n.b: x])
        #expect(abs(out[3000] - 0.5) < 2e-3)
        let dry = nested(effects: [])
        #expect(abs(play(dry.outer, seqs: dry.seqs, sources: [dry.a: x, dry.b: x])[3000] - 0.8) < 1e-3)
    }

    @Test func nestVolumeAfterAndAudioGainBeforeTheEffects() {
        let x = [Float](repeating: 0.1, count: 30_000)
        let quieter = nested(effects: [limit]) { $0.animation.volume = AnimatedProperty(0.5); $0.audioGainDB = 12.0412 }
        // 0.2 summed, x4 Audio Gain = 0.8 into the limiter -> 0.5, then Volume 0.5 -> 0.25.
        #expect(abs(play(quieter.outer, seqs: quieter.seqs, sources: [quieter.a: x, quieter.b: x])[3000] - 0.25) < 2e-3)
    }

    @Test func aSwitchedOffNestEffectLeavesTheSoundAloneAtAnyStart() {
        let nrOff = [(ClipEffect.audioNoiseReductionKind, [String: Double](), false)]
        let n = nested(effects: nrOff), d = nested(effects: [])
        let b = wobble.map { $0 * 0.5 }
        for from: Int64 in [0, 7_000] {
            let wet = play(n.outer, seqs: n.seqs, sources: [n.a: wobble, n.b: b], from: from)
            let dry = play(d.outer, seqs: d.seqs, sources: [d.a: wobble, d.b: b], from: from)
            #expect(zip(wet, dry).allSatisfy { abs($0 - $1) < 1e-6 }, "from \(from)")
        }
    }

    @Test func innerClipEffectsStillRunInsideAnEffectedNest() {
        let a = UUID()
        var c = Clip(name: "c", media: a, kind: .audio, source: TimeRange(start: .zero, duration: frames(20_000)), start: .zero)
        if let id = c.addEffect(kind: ClipEffect.audioGainKind) { c.setParameter(id, ClipEffect.audioGainKey, to: 6.0206) }
        let inner = Timeline(name: "inner", format: fmt, tracks: [Track(kind: .audio, clips: [c])])
        var nest = Clip(name: "n", media: inner.id, kind: .audio, source: TimeRange(start: .zero, duration: frames(20_000)),
                        start: .zero, sequence: inner.id)
        if let id = nest.addEffect(kind: ClipEffect.audioGainKind) { nest.setParameter(id, ClipEffect.audioGainKey, to: 6.0206) }
        let outer = Timeline(name: "outer", format: fmt, tracks: [Track(kind: .audio, clips: [nest])])
        let out = play(outer, seqs: [inner.id: inner], sources: [a: [Float](repeating: 0.1, count: 30_000)])
        #expect(abs(out[3000] - 0.4) < 2e-3)
    }

    /// Block splits do not change the result (state carries across blocks; the chain sees one contiguous stream).
    @Test func blockSizeDoesNotChangeTheNestResult() {
        let comp = (ClipEffect.audioLimiterKind, [ClipEffect.limiterCeilingKey: -20.0], true)
        let n = nested(effects: [comp])
        let x = wobble.map { $0 * 4 }
        func run(_ block: Int) -> [Float] {
            let srcs = [n.a: MemoryAudioSource(mono: x), n.b: MemoryAudioSource(mono: wobble)]
            let f = AudioFeeder(timeline: n.outer, ring: RingBuffer(capacity: 1 << 14), blockFrames: block) { srcs[$0]! }
            f.setTimeline(n.outer, sequences: n.seqs)
            f.seek(to: 0, reverse: false)
            _ = f.fill(maxBlocks: 8192 / block)
            var l = [Float](repeating: 0, count: 8192), r = l
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: 8192) } }
            return l
        }
        let a = run(1024), b = run(512)
        #expect(zip(a, b).allSatisfy { abs($0 - $1) < 1e-5 })
    }

    /// Scrubbing mixes with `clipEffects: true`: a -20 dB Gain effect is heard while scrubbing too, on clips and nests.
    @Test func scrubMixHearsClipAndNestEffects() {
        let m = UUID()
        var c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: frames(20_000)), start: .zero)
        if let id = c.addEffect(kind: ClipEffect.audioGainKind) { c.setParameter(id, ClipEffect.audioGainKey, to: -20) }
        let t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [c])])
        let src = MemoryAudioSource(mono: [Float](repeating: 0.25, count: 30_000))
        let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { _ in src }
        var l = [Float](repeating: 0, count: 512), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            f.mix(timeline: t, startFrame: 1000, count: 512, left: lp.baseAddress!, right: rp.baseAddress!, clipEffects: true) } }
        #expect(abs(l[300] - 0.025) < 1e-3)

        let n = nested(effects: [(ClipEffect.audioGainKind, [ClipEffect.audioGainKey: -20], true)])
        let x = [Float](repeating: 0.25, count: 30_000)
        let srcs = [n.a: MemoryAudioSource(mono: x), n.b: MemoryAudioSource(mono: x)]
        let g = AudioFeeder(timeline: n.outer, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { srcs[$0]! }
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            g.mix(timeline: n.outer, sequences: n.seqs, startFrame: 1000, count: 512, left: lp.baseAddress!, right: rp.baseAddress!,
                  clipEffects: true) } }
        #expect(abs(l[300] - 0.05) < 1e-3)
    }

    @Test func scrubAudioGrainsHearClipEffects() {
        let m = UUID()
        var c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(6, 1)), start: .zero)
        if let id = c.addEffect(kind: ClipEffect.audioGainKind) { c.setParameter(id, ClipEffect.audioGainKey, to: -20) }
        let tl = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .audio, clips: [c])])
        let src = MemoryAudioSource(mono: [Float](repeating: 0.5, count: 6 * 48_000))
        let s = ScrubAudio(resolver: { _ in src }, inline: true)
        s.setTimeline(tl, sequences: [:])
        s.begin(at: Time(48_000, 48_000), hostNanos: 0)
        s.scrub(to: Time(48_200, 48_000), hostNanos: 100_000)
        var l = [Float](repeating: 0, count: 2000), r = l
        _ = l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            s.voice.render(left: lp.baseAddress!, right: rp.baseAddress!, count: 2000) } }
        let peak = l.map { abs($0) }.max() ?? 0
        #expect(peak > 0.02 && peak < 0.06, "peak \(peak)")
    }
}
