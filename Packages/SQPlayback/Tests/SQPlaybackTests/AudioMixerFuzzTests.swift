import Testing
import Foundation
import SQCore
import SQMedia
import SQAudioFX
@testable import SQPlayback

/// Mixer fuzz: random audio timelines (speeds, reverse, gains, track faders, clip and nest effects, nests) through the
/// playback path (`fill`) and the scrub path (`mix`). Nothing may trap, every sample must be finite, and a timeline whose
/// sources are silent must stay silent.
@Suite struct AudioMixerFuzzTests {
    struct LCG {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
        mutating func double() -> Double { Double(next() % 1_000_000) / 1_000_000 }
    }

    static let fmt = SequenceFormat(frameDuration: Time(1, 30))
    static let effects = [ClipEffect.audioGainKind, ClipEffect.audioLimiterKind, ClipEffect.audioNoiseReductionKind]

    static func randomClip(_ rng: inout LCG, media: UUID, mediaLen: Int64, at start: Int64, sequence: Timeline.ID? = nil) -> Clip {
        let from = Int64(rng.int(Int(mediaLen / 2)))
        let len = Int64(1 + rng.int(Int(mediaLen - from - 1)))
        var c = Clip(name: "c", media: media, kind: .audio, source: TimeRange(start: Time(from, 48_000), duration: Time(len, 48_000)),
                     start: Time(start, 48_000), mediaDuration: Time(mediaLen, 48_000), sequence: sequence)
        if sequence == nil {
            c.speed = ClipSpeed(percent: [50.0, 100, 100, 150, 200][rng.int(5)])
            c.reversed = rng.int(4) == 0
        }
        c.audioGainDB = Double(rng.int(25)) - 12
        c.animation.volume = AnimatedProperty(rng.double() * 1.5)
        for _ in 0..<rng.int(3) {
            if let id = c.addEffect(kind: effects[rng.int(effects.count)]) {
                if let i = c.effects.firstIndex(where: { $0.id == id }) { c.effects[i].enabled = rng.int(4) != 0 }
            }
        }
        return c
    }

    static func randomTimeline(_ rng: inout LCG, medias: [UUID], mediaLen: Int64) -> (Timeline, [Timeline.ID: Timeline]) {
        func tracks(_ rng: inout LCG, nest: Timeline? = nil) -> [Track] {
            (0..<(1 + rng.int(3))).map { _ in
                var t = Track(kind: .audio)
                t.volumeDB = Double(rng.int(19)) - 12
                t.pan = rng.double() * 2 - 1
                var pos: Int64 = Int64(rng.int(4_000))
                for _ in 0..<(1 + rng.int(3)) {
                    var c: Clip
                    if let nest, rng.int(3) == 0 {
                        c = randomClip(&rng, media: nest.id, mediaLen: mediaLen, at: pos, sequence: nest.id)
                    } else {
                        c = randomClip(&rng, media: medias[rng.int(medias.count)], mediaLen: mediaLen, at: pos)
                    }
                    c.start = Time(pos, 48_000).snapped(to: fmt.frameDuration)
                    if (try? t.overwrite(c)) != nil { pos = (c.timeline.end.value * 48_000 / c.timeline.end.timescale) + Int64(rng.int(3_000)) }
                }
                return t
            }
        }
        let inner = Timeline(name: "inner", format: fmt, tracks: tracks(&rng))
        let outer = Timeline(name: "outer", format: fmt, tracks: tracks(&rng, nest: inner))
        return (outer, [inner.id: inner])
    }

    /// `mix` longer than one block used to trap (precondition); it now mixes in block chunks, same as block-sized calls.
    @Test func mixLongerThanABlockEqualsBlockSizedMixes() {
        var rng = LCG(s: 99)
        let m = UUID()
        let (t, seqs) = Self.randomTimeline(&rng, medias: [m], mediaLen: 40_000)
        let src = MemoryAudioSource(mono: (0..<40_000).map { Float(sin(Double($0) * 0.03)) * 0.5 })
        let a = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 256) { _ in src }
        let b = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 256) { _ in src }
        var l = [Float](repeating: 0, count: 700), r = l, l2 = l, r2 = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            a.mix(timeline: t, sequences: seqs, startFrame: 3000, count: 700, left: lp.baseAddress!, right: rp.baseAddress!, clipEffects: false) } }
        l2.withUnsafeMutableBufferPointer { lp in r2.withUnsafeMutableBufferPointer { rp in
            for (o, n) in [(0, 256), (256, 256), (512, 188)] {
                b.mix(timeline: t, sequences: seqs, startFrame: 3000 + Int64(o), count: n, left: lp.baseAddress! + o, right: rp.baseAddress! + o, clipEffects: false)
            } } }
        #expect(l == l2 && r == r2)
    }

    @Test(arguments: Array(1...25) as [UInt64])
    func randomMixesStayFiniteAndSilenceStaysSilent(seed: UInt64) {
        var rng = LCG(s: seed &* 7919)
        let medias = [UUID(), UUID()]
        let len: Int64 = 40_000
        let (t, seqs) = Self.randomTimeline(&rng, medias: medias, mediaLen: len)
        let noise = (0..<Int(len)).map { Float(sin(Double($0) * 0.05 + Double(seed))) * 0.9 }
        for silent in [false, true] {
            let srcs = Dictionary(uniqueKeysWithValues: medias.map { ($0, MemoryAudioSource(mono: silent ? [Float](repeating: 0, count: Int(len)) : noise)) })
            let block = [256, 512, 1024][rng.int(3)]
            let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 15), blockFrames: block) { srcs[$0] ?? MemoryAudioSource(mono: []) }
            f.setTimeline(t, sequences: seqs)
            for from in [Int64(0), Int64(rng.int(30_000))] {
                f.seek(to: from, reverse: from > 0 && rng.int(4) == 0)
                _ = f.fill(maxBlocks: 16_384 / block)
                var l = [Float](repeating: 0, count: 8192), r = l
                _ = l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                    f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: 8192) } }
                #expect(l.allSatisfy(\.isFinite) && r.allSatisfy(\.isFinite), "seed \(seed) from \(from): non-finite sample")
                if silent { #expect(l.allSatisfy { abs($0) < 1e-6 } && r.allSatisfy { abs($0) < 1e-6 }, "seed \(seed): silence not silent") }
            }
            var l = [Float](repeating: 0, count: 777), r = l
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                f.mix(timeline: t, sequences: seqs, startFrame: Int64(rng.int(40_000)), count: 777,
                      left: lp.baseAddress!, right: rp.baseAddress!, clipEffects: rng.int(2) == 0) } }
            #expect(l.allSatisfy(\.isFinite) && r.allSatisfy(\.isFinite), "seed \(seed): scrub mix non-finite")
        }
    }
}
