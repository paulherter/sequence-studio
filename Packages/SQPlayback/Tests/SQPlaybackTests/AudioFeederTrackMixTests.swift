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

/// Clip gain, track fader and pan on top of main's crossfades, time remapping and Enable/Disable: each exactly once.
@Suite struct AudioFeederMixCombinationTests {
    private let ma = UUID(), mb = UUID()
    private func crossfaded(gainDB: Double = 0, volumeDB: Double = 0, pan: Double = 0) throws -> (Timeline, UUID, UUID) {
        let fd = Time(1, 30)
        var a = Clip(name: "A", media: ma, kind: .audio, source: TimeRange(start: Time(1, 1), duration: Time(2, 1)), start: .zero, mediaDuration: Time(6, 1))
        var b = Clip(name: "B", media: mb, kind: .audio, source: TimeRange(start: Time(2, 1), duration: Time(2, 1)), start: Time(2, 1), mediaDuration: Time(6, 1))
        a.audioGainDB = gainDB; b.audioGainDB = gainDB
        var track = Track(kind: .audio); try track.overwrite(a); try track.overwrite(b)
        track.volumeDB = volumeDB; track.pan = pan
        var t = Timeline(name: "t", format: SequenceFormat(frameDuration: fd), tracks: [track])
        try t.addTransition(kind: .constantGain, track: track.id, outgoing: a.id, incoming: b.id, duration: fd * 15)
        return (t, ma, mb)
    }

    private func render(_ t: Timeline, _ ma: UUID, _ mb: UUID) -> (l: [Float], r: [Float]) {
        let src: [UUID: MemoryAudioSource] = [ma: constant(6 * 48_000, 0.4), mb: constant(6 * 48_000, 0.4)]
        let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 16384) { src[$0]! }
        return mixed(f, t, from: Int64(1.85 * 48_000), count: 14_400)
    }

    @Test func gainAndFaderApplyOnceThroughACrossfade() throws {
        let (t0, ma, mb) = try crossfaded()
        let base = render(t0, ma, mb)
        #expect(base.l.contains { $0 != 0 })
        let (t1, _, _) = try crossfaded(gainDB: 6.0206)
        let (t2, _, _) = try crossfaded(volumeDB: -6.0206)
        let g = render(t1, ma, mb), v = render(t2, ma, mb)
        for i in stride(from: 0, to: 14_400, by: 211) where base.l[i] > 1e-3 {
            #expect(abs(g.l[i] / base.l[i] - 2) < 2e-3, "gain once at \(i)")
            #expect(abs(v.l[i] / base.l[i] - 0.5) < 2e-3, "fader once at \(i)")
        }
    }

    @Test func hardPanSilencesOneSideThroughACrossfade() throws {
        let (t, ma, mb) = try crossfaded(pan: 1)
        let o = render(t, ma, mb)
        #expect(o.l.allSatisfy { abs($0) < 1e-6 } && o.r.contains { abs($0) > 1e-3 })
    }

    @Test func gainAndFaderApplyOnceWithTimeRemapping() {
        let m = UUID()
        func tl(gain: Double, fader: Double) -> Timeline {
            var c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero, mediaDuration: Time(2, 1))
            c.setSpeedKeys(SpeedKeys(segments: [SpeedSegment(duration: Time(1, 2), from: ClipSpeed(percent: 100)), SpeedSegment(duration: Time(1, 2), from: ClipSpeed(percent: 200))],
                                     origin: .zero))
            c.audioGainDB = gain
            var tr = Track(kind: .audio, clips: [c]); tr.volumeDB = fader
            return Timeline(name: "t", format: fmt, tracks: [tr])
        }
        let src = constant(2 * 48_000, 0.4)
        func run(_ t: Timeline) -> [Float] { played(feeder(t, m, src), 2048).l }
        let base = run(tl(gain: 0, fader: 0)), both = run(tl(gain: 6.0206, fader: -6.0206))
        let ratios = (400..<1500).compactMap { base[$0] > 1e-3 ? both[$0] / base[$0] : nil }
        #expect(!ratios.isEmpty && ratios.allSatisfy { abs($0 - 1) < 2e-3 })
        let up = run(tl(gain: 6.0206, fader: 0))
        let r2 = (400..<1500).compactMap { base[$0] > 1e-3 ? up[$0] / base[$0] : nil }
        #expect(!r2.isEmpty && r2.allSatisfy { abs($0 - 2) < 2e-3 })
    }

    @Test func disabledClipIsSilentWhateverTheGain() {
        let m = UUID()
        var c = Clip(name: "c", media: m, kind: .audio, source: TimeRange(start: .zero, duration: frames(20_000)), start: .zero)
        c.audioGainDB = 12; c.isEnabled = false
        var tr = Track(kind: .audio, clips: [c]); tr.volumeDB = 6; tr.pan = 0.5
        let t = Timeline(name: "t", format: fmt, tracks: [tr])
        let o = mixed(feeder(t, m, constant(30_000)), t, from: 0, count: 512)
        #expect(o.l.allSatisfy { $0 == 0 } && o.r.allSatisfy { $0 == 0 })
    }
}
