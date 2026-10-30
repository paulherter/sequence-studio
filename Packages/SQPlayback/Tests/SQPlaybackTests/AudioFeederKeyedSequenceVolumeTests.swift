import Testing
import Foundation
import SQCore
import SQMedia
import SQAudioFX
@testable import SQPlayback

// Keyed Sequence Volume (v86): the level follows `Timeline.masterVolumeKeys` in playback (fill), scrub (mix) and any block
// split, evaluated on the absolute 256-frame grid.

private let rate: Int64 = 48_000
private let fmt = SequenceFormat(frameDuration: Time(1, 30))

private func keyedTimeline(_ m: UUID) -> Timeline {
    let c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(40_000, rate)), start: .zero)
    var t = Timeline(name: "t", format: fmt, tracks: [Track(kind: .audio, clips: [c])])
    t.setMasterVolumeKey(at: .zero, db: 0)
    t.setMasterVolumeKey(at: Time(1, 1), db: -12)
    return t
}

private func feeder(_ t: Timeline, block: Int = 1024) -> AudioFeeder {
    let src = MemoryAudioSource(mono: [Float](repeating: 0.5, count: 60_000))
    return AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 15), blockFrames: block) { _ in src }
}

private func mixed(_ f: AudioFeeder, _ t: Timeline, from: Int64, count: Int) -> [Float] {
    var l = [Float](repeating: 9, count: count), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        f.mix(timeline: t, startFrame: from, count: count, left: lp.baseAddress!, right: rp.baseAddress!, clipEffects: false) } }
    return l
}

@Suite struct AudioFeederKeyedSequenceVolumeTests {
    @Test func scrubFollowsTheKeysOnTheGrid() {
        let m = UUID(), t = keyedTimeline(m)
        let o = mixed(feeder(t), t, from: 0, count: 4096)
        #expect(o[0] == 0.5)
        for i in [256, 1000, 2048, 4000] {                       // on a grid point the gain is the curve's own
            if i % 256 == 0 {
                let want = Float(0.5 * t.masterGain(at: Time(Int64(i), rate)))
                #expect(abs(o[i] - want) < 1e-5, "frame \(i)")
            }
        }
        #expect(o[4000] < o[1000] && o[1000] < o[0])
    }

    @Test func anySplitOfTheRangeGivesTheSameSamples() {
        let m = UUID(), t = keyedTimeline(m)
        let whole = mixed(feeder(t), t, from: 300, count: 3000)
        var parts: [Float] = []
        var at: Int64 = 300
        for n in [700, 1, 999, 1300] { parts += mixed(feeder(t), t, from: at, count: n); at += Int64(n) }
        #expect(parts == whole)
    }

    @Test func playbackMatchesScrub() {
        let m = UUID(), t = keyedTimeline(m)
        let f = feeder(t)
        f.seek(to: 0, reverse: false)
        _ = f.fill(maxBlocks: 4)
        var l = [Float](repeating: 0, count: 4096), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: 4096) } }
        #expect(l == mixed(feeder(t), t, from: 0, count: 4096))
    }

    @Test func unkeyedStaysConstant() {
        let m = UUID()
        var t = keyedTimeline(m)
        t.clearMasterVolumeKeys(keeping: -6.0206)
        #expect(mixed(feeder(t), t, from: 0, count: 2048).allSatisfy { abs($0 - 0.25) < 1e-4 })
    }

    // MARK: latency and mid-block nests

    private func dryDenoise() -> TrackAudioPreset { TrackAudioPreset(id: "t.dn", name: "dn", compressor: .neutral, noiseReduction: 1e-9) }

    private func keyed(_ t: inout Timeline) {
        t.setMasterVolumeKey(at: .zero, db: 0)
        t.setMasterVolumeKey(at: Time(2400, rate), db: -40)
    }

    private func played(_ f: AudioFeeder, _ n: Int) -> [Float] {
        var l = [Float](repeating: 0, count: n), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: n) } }
        return l
    }

    /// The level follows the sound it multiplies: with 480 samples of FX latency the output is 480 behind the timeline, so a
    /// key at frame F lands at output sample F + 480 (forward play).
    @Test func keysFollowTheDelayCompensatedSoundForward() {
        let m = UUID()
        let c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(8000, rate)), start: .zero)
        let tr = Track(kind: .audio, clips: [c])
        var t = Timeline(name: "t", format: fmt, tracks: [tr]); keyed(&t)
        let src = MemoryAudioSource(mono: [Float](repeating: 0.5, count: 8000))
        let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 15), blockFrames: 1000) { _ in src }
        f.setTracks([tr.id: dryDenoise()])
        f.seek(to: 0, reverse: false); _ = f.fill(maxBlocks: 4)
        #expect(f.outputLatencySamples == 480)
        let o = played(f, 4000)
        for n in 0...8 {
            let frame = Int64(n * 256)
            let want = Float(0.5 * t.masterGain(at: Time(frame, rate)))
            #expect(abs(o[Int(frame) + 480] - want) < 1e-3, "frame \(frame)")
        }
    }

    /// Reverse: the delay line holds play-earlier (higher) frames, so output sample k carries frame 3479 - k.
    @Test func keysFollowTheDelayCompensatedSoundReverse() {
        let m = UUID()
        let c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(4000, rate)), start: .zero)
        let tr = Track(kind: .audio, clips: [c])
        var t = Timeline(name: "t", format: fmt, tracks: [tr]); keyed(&t)
        let src = MemoryAudioSource(mono: [Float](repeating: 0.5, count: 4000))
        let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 15), blockFrames: 1000) { _ in src }
        f.setTracks([tr.id: dryDenoise()])
        f.seek(to: 3000, reverse: true); _ = f.fill(maxBlocks: 3)
        #expect(f.outputLatencySamples == 480)
        let o = played(f, 3000)
        for frame in [2816, 2560, 2304, 2048, 1792] {
            let want = Float(0.5 * t.masterGain(at: Time(Int64(frame), rate)))
            #expect(abs(o[3479 - frame] - want) < 1e-3, "frame \(frame)")
        }
    }

    /// A nest clip that starts inside a block (frame 900 of 1024) samples the nested level at its own start, not at the block
    /// start: any block split gives the same samples. The nested level is -40 dB from source second 0.05 on.
    @Test(arguments: [false, true]) func nestStartingMidBlockIsBlockSplitInvariant(withEffect: Bool) {
        let m = UUID()
        let c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(40_000, rate)), start: .zero)
        var inner = Timeline(name: "inner", format: fmt, tracks: [Track(kind: .audio, clips: [c])])
        keyed(&inner)
        var nest = Clip(name: "n", media: inner.id, kind: .audio,
                        source: TimeRange(start: Time(2400, rate), duration: Time(20_000, rate)), start: Time(900, rate), sequence: inner.id)
        if withEffect, let id = nest.addEffect(kind: ClipEffect.audioLimiterKind) { nest.setParameter(id, ClipEffect.limiterCeilingKey, to: 0) }
        let outer = Timeline(name: "outer", format: fmt, tracks: [Track(kind: .audio, clips: [nest])])
        let src = MemoryAudioSource(mono: [Float](repeating: 0.5, count: 60_000))
        func render(block: Int) -> [Float] {
            let f = AudioFeeder(timeline: outer, ring: RingBuffer(capacity: 1 << 15), blockFrames: block) { _ in src }
            f.setTimeline(outer, sequences: [inner.id: inner])
            f.seek(to: 0, reverse: false); _ = f.fill(maxBlocks: 4096 / block)
            return played(f, 4096)
        }
        let reference = render(block: 1024)
        let want = Float(0.5 * pow(10, -40.0 / 20))
        #expect(abs(reference[1100] - want) < 1e-3, "level at the nest start is the keyed one")
        for block in [256, 900, 333 + 1] {
            let o = render(block: block)
            #expect(zip(o[1000..<1023], reference[1000..<1023]).allSatisfy { abs($0 - $1) < 1e-6 }, "block \(block)")
        }
    }
}
