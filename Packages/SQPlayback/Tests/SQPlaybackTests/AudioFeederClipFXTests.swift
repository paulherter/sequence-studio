import Testing
import Foundation
import SQCore
import SQMedia
import SQAudioFX
@testable import SQPlayback

// AUDIO-FX: the feeder runs each audio clip's effect stack (before Volume) on the one mix path playback and export share.

private let rate: Int64 = 48_000
private let fmt = SequenceFormat(frameDuration: Time(1, 30))

private func timeline(_ m: UUID, effects: [(String, [String: Double], Bool)] = [],
                      _ configure: (inout Clip) -> Void = { _ in }) -> Timeline {
    var c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(20_000, rate)), start: .zero)
    configure(&c)
    for (kind, values, enabled) in effects {
        guard let id = c.addEffect(kind: kind) else { continue }
        for (k, v) in values { c.setParameter(id, k, to: v) }
        if let i = c.effects.firstIndex(where: { $0.id == id }) { c.effects[i].enabled = enabled }
    }
    return Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [c])])
}

/// A source whose every sample differs (so a time shift shows), quiet enough for no FX to react.
private let wobble = (0..<30_000).map { Float(0.05 * sin(Double($0) * 0.013) + 0.02 * sin(Double($0) * 0.31)) }

private func play(_ t: Timeline, samples: [Float], from: Int64 = 0, count: Int = 4096) -> [Float] {
    let src = MemoryAudioSource(mono: samples)
    let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { _ in src }
    f.seek(to: from, reverse: false)
    _ = f.fill(maxBlocks: 8)
    var l = [Float](repeating: 0, count: count), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: count) } }
    return l
}

@Suite struct AudioFeederClipFXTests {
    @Test func aGainEffectChangesThePlayedClip() {
        let m = UUID()
        let dry = play(timeline(m), samples: [Float](repeating: 0.25, count: 30_000))
        let wet = play(timeline(m, effects: [(ClipEffect.audioGainKind, [ClipEffect.audioGainKey: 6.0206], true)]),
                       samples: [Float](repeating: 0.25, count: 30_000))
        #expect(abs(dry[2000] - 0.25) < 1e-4)
        #expect(abs(wet[2000] - 0.5) < 1e-3)
    }

    @Test func clipEffectsAlsoRunInReversePlay() {
        let m = UUID()
        let t = timeline(m, effects: [(ClipEffect.audioGainKind, [ClipEffect.audioGainKey: 6.0206], true)])
        let src = MemoryAudioSource(mono: [Float](repeating: 0.25, count: 30_000))
        let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { _ in src }
        f.seek(to: 6_000, reverse: true)
        _ = f.fill(maxBlocks: 4)
        var l = [Float](repeating: 0, count: 2048), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: 2048) } }
        #expect(abs(l[1500] - 0.5) < 1e-3)
    }

    @Test func aSwitchedOffEffectLeavesTheSoundAlone() {
        let m = UUID()
        let dry = play(timeline(m), samples: wobble)
        let off = play(timeline(m, effects: [(ClipEffect.audioGainKind, [ClipEffect.audioGainKey: -30], false)]), samples: wobble)
        #expect(off == dry)
    }

    @Test func listOrderIsProcessingOrder() {
        let m = UUID(), x = [Float](repeating: 0.5, count: 30_000)
        let boost = (ClipEffect.audioGainKind, [ClipEffect.audioGainKey: 6.0206], true)
        let limit = (ClipEffect.audioLimiterKind, [ClipEffect.limiterCeilingKey: -6.0206], true)
        let gainFirst = play(timeline(m, effects: [boost, limit]), samples: x)
        let limiterFirst = play(timeline(m, effects: [limit, boost]), samples: x)
        #expect(abs(gainFirst[3000] - 0.5) < 2e-3)        // +6 dB, then held at -6 dBFS
        #expect(abs(limiterFirst[3000] - 1) < 2e-3)      // nothing to limit, then +6 dB
    }

    /// Noise Reduction adds 480 samples inside the chain; the feeder reads ahead so the clip stays in sync with the timeline.
    @Test func noiseReductionLatencyIsCompensated() {
        let m = UUID()
        let nrOff = [(ClipEffect.audioNoiseReductionKind, [String: Double](), false)]
        #expect(play(timeline(m, effects: nrOff), samples: wobble) == play(timeline(m), samples: wobble))
        // Also after a seek into the middle of the clip (the chain is primed again).
        #expect(play(timeline(m, effects: nrOff), samples: wobble, from: 7_000) == play(timeline(m), samples: wobble, from: 7_000))
    }

    @Test func scrubMixStaysDry() {
        let m = UUID()
        let t = timeline(m, effects: [(ClipEffect.audioGainKind, [ClipEffect.audioGainKey: -20], true)])
        let src = MemoryAudioSource(mono: [Float](repeating: 0.25, count: 30_000))
        let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { _ in src }
        var l = [Float](repeating: 0, count: 512), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            f.mix(timeline: t, startFrame: 1000, count: 512, left: lp.baseAddress!, right: rp.baseAddress!, clipEffects: false) } }
        #expect(abs(l[300] - 0.25) < 1e-4)
    }

    /// Audio Gain is the clip's input level (Premiere): it goes in before the effects, so a Hard Limiter after it holds its
    /// ceiling even with +12 dB of gain. Volume stays after the effects.
    @Test func audioGainGoesInBeforeTheEffects() {
        let m = UUID(), x = [Float](repeating: 0.25, count: 30_000)
        let limit = (ClipEffect.audioLimiterKind, [ClipEffect.limiterCeilingKey: -6.0206], true)
        let t = timeline(m, effects: [limit]) { $0.audioGainDB = 12.0412 }     // x4: 0.25 -> 1.0 into the limiter
        let held = play(t, samples: x)
        #expect(abs(held[3000] - 0.5) < 2e-3)
        #expect(held[1000...].allSatisfy { abs($0) <= 0.5 + 1e-3 })
        // Volume after the chain: -6 dB on the limited signal.
        let quieter = timeline(m, effects: [limit]) { $0.audioGainDB = 12.0412; $0.animation.volume = AnimatedProperty(0.5) }
        #expect(abs(play(quieter, samples: x)[3000] - 0.25) < 2e-3)
        // Without effects Audio Gain stays a plain level.
        let dry = timeline(m) { $0.audioGainDB = 12.0412 }
        #expect(abs(play(dry, samples: x)[3000] - 1) < 2e-3)
    }

    /// A retimed clip reads ahead through the retimer too: a switched-off Noise Reduction (a delayed dry path) plays exactly
    /// like no effect, at both pitch modes, from the start and after a seek.
    @Test func noiseReductionLatencyIsCompensatedOnRetimedClips() {
        let m = UUID()
        let nrOff = [(ClipEffect.audioNoiseReductionKind, [String: Double](), false)]
        for keepsPitch in [false, true] {
            let retime: (inout Clip) -> Void = { $0.speed = ClipSpeed(percent: 50); $0.keepsPitch = keepsPitch }
            let long = wobble + wobble
            for from: Int64 in [0, 7_000] {
                let a = play(timeline(m, effects: nrOff, retime), samples: long, from: from)
                let b = play(timeline(m, retime), samples: long, from: from)
                #expect(a == b, "keepsPitch \(keepsPitch) from \(from)")
            }
        }
    }
}
