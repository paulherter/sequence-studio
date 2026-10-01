import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

private let rate: Int64 = 48_000
private let fmt = SequenceFormat(frameDuration: Time(1, 30))

private func frames(_ n: Int64) -> Time { Time(n, rate) }
private func constant(_ n: Int, _ v: Float = 0.5) -> MemoryAudioSource { MemoryAudioSource(mono: [Float](repeating: v, count: n)) }

private func timeline(_ m: UUID, gainDB: Double = 0, speed: ClipSpeed = .normal, volumeDB: Double = 0, pan: Double = 0) -> Timeline {
    var c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: frames(20_000)), start: .zero)
    c.audioGainDB = gainDB
    if !speed.isNormal { c.speed = speed; c.source = TimeRange(start: .zero, duration: frames(20_000)) }
    var tr = Track(kind: .audio, clips: [c])
    tr.volumeDB = volumeDB; tr.pan = pan
    return Timeline(name: "t", format: fmt, tracks: [tr])
}

private func feeder(_ t: Timeline, _ m: UUID, _ src: MemoryAudioSource) -> AudioFeeder {
    AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { _ in src }
}

private func mixed(_ f: AudioFeeder, _ t: Timeline, from: Int64, count: Int) -> (l: [Float], r: [Float]) {
    var l = [Float](repeating: 9, count: count), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        f.mix(timeline: t, startFrame: from, count: count, left: lp.baseAddress!, right: rp.baseAddress!) } }
    return (l, r)
}

/// Plays through the ring (the path export reads too) and returns the first `n` frames of both channels.
private func played(_ f: AudioFeeder, _ n: Int) -> (l: [Float], r: [Float]) {
    f.seek(to: 0, reverse: false)
    _ = f.fill(maxBlocks: 4)
    var l = [Float](repeating: 0, count: n), r = l
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        _ = f.ring.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: n) } }
    return (l, r)
}

@Suite struct AudioFeederTrackMixTests {
    @Test func hardLeftSilencesTheRightChannelAndCentreChangesNothing() {
        let m = UUID()
        let centre = timeline(m), left = timeline(m, pan: -1)
        let c = mixed(feeder(centre, m, constant(30_000)), centre, from: 100, count: 512)
        #expect(c.l.allSatisfy { $0 == 0.5 } && c.r.allSatisfy { $0 == 0.5 })
        let o = mixed(feeder(left, m, constant(30_000)), left, from: 100, count: 512)
        #expect(o.r.allSatisfy { $0 == 0 })
        #expect(o.l.allSatisfy { abs(Double($0) - 0.5 * 2.0.squareRoot()) < 1e-5 })
    }

    @Test func faderScalesBothSides() {
        let m = UUID()
        let t = timeline(m, volumeDB: -6.0206)
        let o = mixed(feeder(t, m, constant(30_000)), t, from: 0, count: 256)
        #expect(o.l.allSatisfy { abs($0 - 0.25) < 1e-4 } && o.r == o.l)
    }

    @Test func playbackRingEqualsTheMixPath() {
        let m = UUID()
        let t = timeline(m, gainDB: 3, volumeDB: -2, pan: 0.4)
        let src = constant(30_000)
        let p = played(feeder(t, m, src), 2048)
        let d = mixed(feeder(t, m, src), t, from: 0, count: 1024)
        #expect(Array(p.l[0..<1024]) == d.l && Array(p.r[0..<1024]) == d.r)
    }

    @Test func clipGainIsAppliedExactlyOnceAtAnySpeed() {
        let m = UUID()
        let src = constant(60_000)
        for speed in [ClipSpeed.normal, ClipSpeed(percent: 200), ClipSpeed(percent: 50)] {
            let plain = timeline(m, speed: speed), boosted = timeline(m, gainDB: 6.0206, speed: speed)
            let a = played(feeder(plain, m, src), 1024), b = played(feeder(boosted, m, src), 1024)
            // Compare mid-block samples (a retimer has a short fade-in at the very start).
            let ratios = (300..<900).compactMap { a.l[$0] != 0 ? b.l[$0] / a.l[$0] : nil }
            #expect(!ratios.isEmpty, "speed \(speed)")
            #expect(ratios.allSatisfy { abs($0 - 2) < 1e-3 }, "speed \(speed)")
        }
    }

    @Test func trackFaderAtHalfSpeedStaysSingle() {
        let m = UUID()
        let half = ClipSpeed(percent: 50)
        let a = played(feeder(timeline(m, speed: half), m, constant(60_000)), 1024)
        let b = played(feeder(timeline(m, speed: half, volumeDB: -6.0206), m, constant(60_000)), 1024)
        let ratios = (300..<900).compactMap { a.l[$0] != 0 ? b.l[$0] / a.l[$0] : nil }
        #expect(!ratios.isEmpty && ratios.allSatisfy { abs($0 - 0.5) < 1e-3 })
    }
}
