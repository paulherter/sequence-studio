import Testing
import Foundation
import SQCore
import SQMedia
import SQAudioFX
@testable import SQPlayback

// Sequence Volume (`Timeline.masterVolumeDB`, v66): one gain on the whole sequence after every track fader and before the
// delivery limiter. Playback and export share `fill`; scrubbing (`mix`) applies it too. A nested sequence's level applies
// to its sound inside the parent, before the nest clip's own effects.

private let rate: Int64 = 48_000
private let fmt = SequenceFormat(frameDuration: Time(1, 30))
private let half = -6.0206

private func clip(_ m: UUID) -> Clip {
    Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(20_000, rate)), start: .zero)
}

private func timeline(_ m: UUID, master: Double = 0, fader: Double = 0, target: DeliveryTarget? = nil) -> (Timeline, Track) {
    var tr = Track(kind: .audio, clips: [clip(m)])
    tr.volumeDB = fader
    var t = Timeline(name: "t", format: fmt, tracks: [tr])
    t.masterVolumeDB = master
    t.deliveryTarget = target
    return (t, tr)
}

private func feeder(_ t: Timeline, _ v: Float = 0.5, seqs: [Timeline.ID: Timeline] = [:]) -> AudioFeeder {
    let src = MemoryAudioSource(mono: [Float](repeating: v, count: 30_000))
    let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { _ in src }
    if !seqs.isEmpty { f.setTimeline(t, sequences: seqs) }
    return f
}

private func played(_ f: AudioFeeder, _ n: Int) -> (l: [Float], r: [Float]) {
    f.seek(to: 0, reverse: false)
    _ = f.fill(maxBlocks: 4)
    var l = [Float](repeating: 0, count: n), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: n) } }
    return (l, r)
}

private func mixed(_ f: AudioFeeder, _ t: Timeline, seqs: [Timeline.ID: Timeline] = [:], count: Int) -> (l: [Float], r: [Float]) {
    var l = [Float](repeating: 9, count: count), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        f.mix(timeline: t, sequences: seqs, startFrame: 0, count: count, left: lp.baseAddress!, right: rp.baseAddress!, clipEffects: false) } }
    return (l, r)
}

@Suite struct AudioFeederSequenceVolumeTests {
    @Test func zeroDBIsSampleIdentical() {
        let m = UUID()
        let (plain, _) = timeline(m, fader: -2)
        var zero = plain
        zero.masterVolumeDB = 0
        #expect(played(feeder(plain), 2048) == played(feeder(zero), 2048))
    }

    @Test func minusSixHalvesPlaybackAndScrub() {
        let m = UUID()
        let (t, _) = timeline(m, master: half)
        let p = played(feeder(t), 2048)
        #expect(p.l.allSatisfy { abs($0 - 0.25) < 1e-4 } && p.r == p.l)
        let s = mixed(feeder(t), t, count: 1024)
        #expect(s.l.allSatisfy { abs($0 - 0.25) < 1e-4 } && s.r == s.l)
        #expect(Array(p.l[0..<1024]) == s.l)
    }

    @Test func multipliesWithTheTrackFader() {
        let m = UUID()
        let (t, _) = timeline(m, master: half, fader: half)
        #expect(played(feeder(t), 1024).l.allSatisfy { abs($0 - 0.125) < 1e-4 })
    }

    @Test func floorSilencesTheSequence() {
        let m = UUID()
        let (t, _) = timeline(m, master: TrackPan.minVolumeDB)
        #expect(played(feeder(t), 1024).l.allSatisfy { $0 == 0 })
    }

    /// Before the limiter: a sequence turned down below the ceiling is not limited; one turned up is held at it.
    @Test func appliesBeforeTheDeliveryLimiter() {
        let m = UUID()
        let target = DeliveryTarget(platform: .youtube, targetLUFS: -14, truePeakDB: -1)
        let ceiling = Float(GainMath.linear(fromDB: -1))
        let (down, _) = timeline(m, master: half, target: target)
        let d = played(feeder(down, 0.9), 2048)
        #expect(abs(d.l[1500] - 0.45) < 1e-3)
        let (up, _) = timeline(m, master: 12, target: target)
        let u = played(feeder(up, 0.5), 2048)
        #expect(u.l.allSatisfy { $0 <= ceiling + 1e-4 } && u.l[1500] > ceiling - 0.02)
    }

    /// A live change ramps across one block like a fader move: no step.
    @Test func aChangeRampsWithoutAStep() {
        let m = UUID()
        let (loud, tr) = timeline(m)
        var quiet = Timeline(id: loud.id, name: "t", format: fmt, tracks: [tr])
        quiet.masterVolumeDB = -12
        let f = feeder(loud)
        f.seek(to: 0, reverse: false)
        _ = f.fill(maxBlocks: 1)
        f.setTimeline(quiet)
        _ = f.fill(maxBlocks: 2)
        var l = [Float](repeating: 0, count: 3072), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: 3072) } }
        let target = Float(0.5 * TrackPan.linear(volumeDB: -12))
        let slope = (0.5 - target) / 1024
        #expect(l[100] == 0.5 && abs(l[3000] - target) < 1e-6)
        let maxStep = zip(l, l.dropFirst()).map { abs($0 - $1) }.max()!
        #expect(maxStep <= slope * 1.01 + 1e-7, "largest step \(maxStep) vs ramp slope \(slope)")
    }

    /// The inner sequence's level applies inside the parent; the parent's level multiplies on top.
    @Test func nestedSequenceKeepsItsOwnLevel() {
        let m = UUID()
        var inner = Timeline(name: "inner", format: fmt, tracks: [Track(kind: .audio, clips: [clip(m)])])
        inner.masterVolumeDB = half
        let nest = Clip(name: "n", media: inner.id, kind: .audio, source: TimeRange(start: .zero, duration: Time(20_000, rate)),
                        start: .zero, sequence: inner.id)
        var outer = Timeline(name: "outer", format: fmt, tracks: [Track(kind: .audio, clips: [nest])])
        let seqs = [inner.id: inner]
        #expect(played(feeder(outer, seqs: seqs), 1024).l.allSatisfy { abs($0 - 0.25) < 1e-4 })
        #expect(mixed(feeder(outer), outer, seqs: seqs, count: 512).l.allSatisfy { abs($0 - 0.25) < 1e-4 })
        outer.masterVolumeDB = half
        #expect(played(feeder(outer, seqs: seqs), 1024).l.allSatisfy { abs($0 - 0.125) < 1e-4 })
    }

    /// Inner level before the nest clip's effects (it is part of the nested sequence's sum): 0.4 + 0.4 at -6 dB is 0.4, under
    /// a -6 dBFS (0.5) limiter on the nest clip, so nothing is limited. Applied after the effects it would read 0.25.
    @Test func nestedLevelRunsBeforeTheNestClipsEffects() {
        let a = UUID(), b = UUID()
        var inner = Timeline(name: "inner", format: fmt,
                             tracks: [Track(kind: .audio, clips: [clip(a)]), Track(kind: .audio, clips: [clip(b)])])
        inner.masterVolumeDB = half
        var nest = Clip(name: "n", media: inner.id, kind: .audio, source: TimeRange(start: .zero, duration: Time(20_000, rate)),
                        start: .zero, sequence: inner.id)
        if let id = nest.addEffect(kind: ClipEffect.audioLimiterKind) { nest.setParameter(id, ClipEffect.limiterCeilingKey, to: half) }
        let outer = Timeline(name: "outer", format: fmt, tracks: [Track(kind: .audio, clips: [nest])])
        let src = MemoryAudioSource(mono: [Float](repeating: 0.4, count: 30_000))
        let f = AudioFeeder(timeline: outer, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { _ in src }
        f.setTimeline(outer, sequences: [inner.id: inner])
        f.seek(to: 0, reverse: false)
        _ = f.fill(maxBlocks: 8)
        var l = [Float](repeating: 0, count: 4096), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: 4096) } }
        #expect(abs(l[3000] - 0.4) < 2e-3)
    }
}
